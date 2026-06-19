import SwiftUI

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [Friend] = []
    @Published var requests: [FriendRequest] = []
    @Published var blocked: [BlockedUser] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let service: FriendsServicing
    init(service: FriendsServicing) { self.service = service }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let f = service.list()
            async let r = service.requests()
            async let b = service.blocks()
            friends = try await f
            requests = try await r
            blocked = try await b
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func accept(_ request: FriendRequest) async {
        do { try await service.accept(requestId: request.id); await load() } catch { errorMessage = error.localizedDescription }
    }

    func decline(_ request: FriendRequest) async {
        do { try await service.decline(requestId: request.id); await load() } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ friend: Friend) async {
        do { try await service.remove(userId: friend.userId); await load() } catch { errorMessage = error.localizedDescription }
    }
}

struct FriendsListView: View {
    @StateObject private var model: FriendsViewModel
    @EnvironmentObject private var services: AppServices
    @State private var showAddFriend = false
    init(service: FriendsServicing) {
        _model = StateObject(wrappedValue: FriendsViewModel(service: service))
    }

    private var isEverythingEmpty: Bool {
        model.friends.isEmpty && model.requests.isEmpty && model.blocked.isEmpty
    }

    var body: some View {
        List {
            if model.isLoading && model.friends.isEmpty && model.requests.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if isEverythingEmpty && model.errorMessage == nil {
                EmptyStateView(
                    title: "Aucun ami",
                    message: "Ajoute des membres pour partager ta position et comparer vos mesures.",
                    systemImage: "person.2"
                )
                .listRowBackground(Color.clear)
            }
            if !model.requests.isEmpty {
                Section("Demandes") {
                    ForEach(model.requests) { request in
                        requestRow(request)
                            .listRowBackground(SQColor.surface)
                    }
                }
            }
            Section {
                ForEach(model.friends) { friend in
                    friendRow(friend)
                        .swipeActions {
                            Button(role: .destructive) { Task { await model.remove(friend) } } label: {
                                Label("Retirer", systemImage: "person.fill.xmark")
                            }
                        }
                        .listRowBackground(SQColor.surface)
                }
            } header: {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Mon réseau").sqKicker()
                    Text("Amis (\(model.friends.count))")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if !model.blocked.isEmpty {
                Section("Bloqués") {
                    ForEach(model.blocked) { user in
                        HStack(spacing: SQSpace.md) {
                            SQAvatar(url: user.avatarUrl, name: user.displayName)
                                .opacity(0.55)
                                .accessibilityHidden(true)
                            Text(user.displayName)
                                .font(SQType.body)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        .listRowBackground(SQColor.surface)
                    }
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).font(.footnote).foregroundStyle(SQColor.danger) }
                    .listRowBackground(SQColor.danger.opacity(0.10))
            }
        }
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
        .task { await model.load() }
        .refreshable { await model.load() }
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
            compactButton("Accepter", style: .primary) { Task { await model.accept(request) } }
            compactButton("Refuser", style: .ghost) { Task { await model.decline(request) } }
        }
        .padding(.vertical, SQSpace.xs)
    }

    /// Variante compacte du GradientButton pour les rangées de liste
    /// (mêmes styles primary / ghost, gabarit capsule réduit).
    private func compactButton(_ title: String, style: GradientButton.Style, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            Text(title)
                .font(SQFont.archivo(13, .bold, relativeTo: .footnote))
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .foregroundStyle(style == .primary ? .white : SQColor.label)
                .background {
                    if style == .primary {
                        Capsule().fill(SQColor.brandRed)
                    } else {
                        Capsule().stroke(SQColor.separator, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
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
                        .listRowBackground(SQColor.surface)
                    ForEach(results) { user in
                        HStack(spacing: SQSpace.md) {
                            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 36)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName).foregroundStyle(SQColor.label)
                                Text(user.email).font(.caption).foregroundStyle(SQColor.labelSecondary)
                            }
                            Spacer()
                            if busyId == user.id {
                                ProgressView()
                            } else {
                                Button { Task { await send(user) } } label: {
                                    Image(systemName: "person.badge.plus").foregroundStyle(SQColor.brandRed)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Envoyer une demande à \(user.displayName)")
                            }
                        }
                        .listRowBackground(SQColor.surface)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(SQColor.danger)
                            .listRowBackground(Color.clear)
                    }
                } header: { Text("Ajouter un ami").sqKicker() }
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
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
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
