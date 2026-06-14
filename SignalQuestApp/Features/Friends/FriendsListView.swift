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
    init(service: FriendsServicing) {
        _model = StateObject(wrappedValue: FriendsViewModel(service: service))
    }

    var body: some View {
        List {
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
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private func requestRow(_ request: FriendRequest) -> some View {
        HStack(spacing: SQSpace.sm + 2) {
            SQAvatar(url: request.user?.avatarUrl, name: request.user?.displayName ?? "?")
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
