import SwiftUI

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [Friend] = []
    @Published var receivedRequests: [FriendRequest] = []
    @Published var sentRequests: [FriendRequest] = []
    @Published var blocked: [BlockedUser] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let service: FriendsServicing
    init(service: FriendsServicing) { self.service = service }

    /// Les trois chargements sont INDÉPENDANTS.
    ///
    /// Le code précédent enchaînait trois `try await` dans un seul `do/catch` :
    /// un échec sur `blocks()` — la liste la moins importante — faisait perdre
    /// les amis et les demandes déjà récupérés avec succès, et l'écran
    /// paraissait vide. On conserve désormais ce qui a réussi et on ne signale
    /// que ce qui a échoué.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        // `Result(catching:)` n'a pas de variante asynchrone : on encapsule.
        let service = self.service
        async let friendsResult = Self.attempt { try await service.list() }
        async let requestsResult = Self.attempt { try await service.requests() }
        async let blocksResult = Self.attempt { try await service.blocks() }

        var failures: [Error] = []

        switch await friendsResult {
        case .success(let value): friends = value
        case .failure(let error): failures.append(error)
        }
        switch await requestsResult {
        case .success(let value):
            receivedRequests = value.received
            sentRequests = value.sent
        case .failure(let error): failures.append(error)
        }
        switch await blocksResult {
        case .success(let value): blocked = value
        case .failure(let error): failures.append(error)
        }

        // Une annulation (changement d'écran, rafraîchissement concurrent) n'est
        // pas une erreur à montrer.
        let reportable = failures.filter { !$0.isCancellation }
        errorMessage = reportable.first.map { $0.localizedDescription }
    }

    func accept(_ request: FriendRequest) async {
        await perform { try await self.service.accept(requestId: request.id) }
    }

    func decline(_ request: FriendRequest) async {
        await perform { try await self.service.decline(requestId: request.id) }
    }

    /// Annule une demande que j'ai envoyée.
    func cancel(_ request: FriendRequest) async {
        await perform { try await self.service.cancelRequest(requestId: request.id) }
    }

    func remove(_ friend: Friend) async {
        await perform { try await self.service.remove(userId: friend.userId) }
    }

    /// Sans cette action, un blocage était définitif : aucun moyen de revenir en
    /// arrière depuis l'app.
    func unblock(_ user: BlockedUser) async {
        await perform { try await self.service.unblock(userId: user.userId) }
    }

    private nonisolated static func attempt<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct FriendsListView: View {
    @StateObject private var model: FriendsViewModel
    @EnvironmentObject private var services: AppServices
    @State private var showAddFriend = false
    /// Ami dont on consulte le profil public (push UserProfileView).
    @State private var profileAuthor: SocialFeedAuthor?
    /// Débloquer réintroduit quelqu'un dans le champ social de l'utilisateur :
    /// confirmation explicite, comme pour bloquer.
    @State private var unblockTarget: BlockedUser?
    init(service: FriendsServicing) {
        _model = StateObject(wrappedValue: FriendsViewModel(service: service))
    }

    private var isUnblockConfirmationPresented: Binding<Bool> {
        Binding(
            get: { unblockTarget != nil },
            set: { if !$0 { unblockTarget = nil } }
        )
    }

    private var isEverythingEmpty: Bool {
        model.friends.isEmpty && model.receivedRequests.isEmpty
            && model.sentRequests.isEmpty && model.blocked.isEmpty
    }

    var body: some View {
        List {
            if model.isLoading && model.friends.isEmpty && model.receivedRequests.isEmpty {
                ProgressView().tint(SQColor.brandRed).frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if isEverythingEmpty && model.errorMessage == nil {
                EmptyStateView(
                    title: "Aucun ami",
                    message: "Ajoute des membres pour partager ta position et comparer vos mesures.",
                    systemImage: "person.2"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if !model.receivedRequests.isEmpty {
                Section {
                    ForEach(model.receivedRequests) { request in
                        cardRow { requestRow(request) }
                    }
                } header: {
                    sectionHeader("Demandes reçues")
                }
            }
            if !model.sentRequests.isEmpty {
                Section {
                    ForEach(model.sentRequests) { request in
                        cardRow { sentRequestRow(request) }
                    }
                } header: {
                    sectionHeader("Demandes envoyées")
                }
            }
            Section {
                ForEach(model.friends) { friend in
                    Button {
                        Haptics.light()
                        profileAuthor = SocialFeedAuthor(
                            id: friend.userId,
                            name: friend.name,
                            handle: friend.handle,
                            avatarUrl: friend.avatarUrl,
                            isFriend: true,
                            isFollowing: nil,
                            liveRadio: nil
                        )
                    } label: {
                        cardSurface { friendRow(friend) }
                            .contentShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
                    .swipeActions {
                        Button(role: .destructive) { Task { await model.remove(friend) } } label: {
                            Label("Retirer", systemImage: "person.fill.xmark")
                        }
                    }
                    .accessibilityHint("Ouvre le profil de \(friend.displayName)")
                }
            } header: {
                sectionHeader("Amis (\(model.friends.count))")
            }
            if !model.blocked.isEmpty {
                Section {
                    ForEach(model.blocked) { user in
                        cardRow {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: user.avatarUrl, name: user.displayName)
                                    .opacity(0.55)
                                    .accessibilityHidden(true)
                                Text(user.displayName)
                                    .font(SQType.body)
                                    .foregroundStyle(SQColor.labelSecondary)
                                Spacer()
                                Button("Débloquer") {
                                    Haptics.light()
                                    unblockTarget = user
                                }
                                .font(SQType.button)
                                .foregroundStyle(SQColor.brandRed)
                                .buttonStyle(.plain)
                                .accessibilityLabel("Débloquer \(user.displayName)")
                            }
                        }
                    }
                } header: {
                    sectionHeader("Bloqués")
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SQSpace.md + 2)
                        .background(SQColor.dangerSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Amis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddFriend = true } label: {
                    Image(systemName: "person.badge.plus").foregroundStyle(SQColor.brandRed)
                }
                .accessibilityLabel("Ajouter un ami")
            }
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet(messages: services.messages, friends: services.friends) {
                await model.load()
            }
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: services.feed)
        }
        .onChangeCompat(of: profileAuthor) { _, newValue in
            // Au retour du profil, l'amitié a pu être retirée ou l'utilisateur
            // bloqué : on resynchronise la liste.
            if newValue == nil { Task { await model.load() } }
        }
        .confirmationDialog(
            "Débloquer cette personne ?",
            isPresented: isUnblockConfirmationPresented,
            titleVisibility: .visible,
            presenting: unblockTarget
        ) { user in
            Button("Débloquer") {
                unblockTarget = nil
                Task { await model.unblock(user) }
            }
            Button("Annuler", role: .cancel) { unblockTarget = nil }
        } message: { user in
            Text("\(user.displayName) pourra de nouveau voir ton profil et te contacter.")
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    /// Demande que J'AI envoyée : on affiche le destinataire (et non
    /// l'expéditeur, qui serait moi), avec l'annulation.
    private func sentRequestRow(_ request: FriendRequest) -> some View {
        let recipient = request.recipient
        let name: String = recipient?.displayName ?? "Utilisateur"
        let avatar: URL? = recipient?.avatarUrl
        return HStack(spacing: SQSpace.md) {
            SQAvatar(url: avatar, name: name)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                Text("En attente de réponse")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
            Button("Annuler") {
                Haptics.light()
                Task { await model.cancel(request) }
            }
            .font(SQType.button)
            .foregroundStyle(SQColor.labelSecondary)
            .buttonStyle(.plain)
            .accessibilityLabel("Annuler la demande envoyée à \(name)")
        }
    }

    /// En-tête de section Figtree, casse normale (plus de MAJUSCULES système).
    private func sectionHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .textCase(nil)
    }

    /// Habillage carte douce seul (surface, rayon 14, ombre repos), sans les
    /// réglages de rangée de liste — réutilisé par la rangée-bouton des amis
    /// pour que le press scale s'applique à toute la carte.
    private func cardSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, SQSpace.md + 2)
            .padding(.vertical, SQSpace.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .sqShadowSoft()
    }

    /// Rangée-carte douce : surface, rayon 14, ombre repos.
    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        cardSurface(content: content)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
    }

    private func requestRow(_ request: FriendRequest) -> some View {
        HStack(spacing: SQSpace.sm + 2) {
            SQAvatar(url: request.user?.avatarUrl, name: request.user?.displayName ?? "?")
                .accessibilityHidden(true)
            Text(request.user?.displayName ?? "Utilisateur")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
            Spacer(minLength: SQSpace.sm)
            compactButton("Accepter", accented: true) { Task { await model.accept(request) } }
            compactButton("Refuser", accented: false) { Task { await model.decline(request) } }
        }
        .padding(.vertical, SQSpace.xs)
    }

    /// Petits boutons capsule des rangées : accepter = brique pleine,
    /// refuser = tuile crème secondaire — sans bordure (règle No-Border).
    private func compactButton(_ title: String, accented: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            Text(LocalizedStringKey(title))
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .foregroundStyle(accented ? SQColor.onAccent : SQColor.label)
                .background(accented ? SQColor.brandRed : SQColor.surfaceMuted, in: Capsule(style: .continuous))
                .padding(.vertical, SQSpace.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
    }

    private func friendRow(_ friend: Friend) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                SQAvatar(url: friend.avatarUrl, name: friend.displayName)
                if friend.presence?.isOnline == true {
                    Circle().fill(SQColor.success).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(SQColor.surface, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.label)
                if let custom = friend.presence?.customStatus {
                    Text(custom).font(.caption).foregroundStyle(SQColor.labelSecondary)
                } else if let last = friend.presence?.lastSeenAt, friend.presence?.isOnline != true {
                    Text(last, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, SQSpace.xxs)
    }
}

/// FRND-UX-01 : recherche d'utilisateurs + envoi d'une demande d'ami.
private struct AddFriendSheet: View {
    let messages: MessagesServicing
    let friends: FriendsServicing
    let onSent: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var results: [MessageSearchUser] = []
    @State private var busyId: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Nom, handle ou email", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.lg)
                        .frame(height: 44)
                        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: SQSpace.lg, bottom: SQSpace.sm, trailing: SQSpace.lg))
                    ForEach(results) { user in
                        HStack(spacing: SQSpace.md) {
                            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 36)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName)
                                    .font(SQType.body)
                                    .foregroundStyle(SQColor.label)
                                Text(user.email)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            Spacer()
                            if busyId == user.id {
                                ProgressView().tint(SQColor.brandRed)
                            } else {
                                Button { Task { await send(user) } } label: {
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(SQColor.brandRed)
                                        .frame(width: 38, height: 38)
                                        .background(SQColor.accentSoft, in: Circle())
                                        .padding(3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(SQPressButtonStyle())
                                .accessibilityLabel("Envoyer une demande à \(user.displayName)")
                            }
                        }
                        .listRowBackground(SQColor.surface)
                        .listRowSeparatorTint(SQColor.separator)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(SQType.caption).foregroundStyle(SQColor.danger)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Résultats")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Ajouter un ami")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .onChangeCompat(of: query) { _, _ in
                // Debounce annulable : annule la requête précédente avant d'en relancer
                // une et abandonne si annulée pendant l'attente — évite les rafales
                // réseau et les réponses périmées qui écrasent les récentes.
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await search()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        results = (try? await messages.searchUsers(query: trimmed)) ?? []
    }

    private func send(_ user: MessageSearchUser) async {
        busyId = user.id
        errorMessage = nil
        defer { busyId = nil }
        do {
            try await friends.sendRequest(toUserId: user.id)
            Haptics.success()
            await onSent()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
