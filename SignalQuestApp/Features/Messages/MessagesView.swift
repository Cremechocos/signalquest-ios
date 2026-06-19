import SwiftUI

@MainActor
final class MessagesViewModel: ObservableObject {
    @Published var conversations: [MessageConversation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Aperçus déchiffrés du dernier message, par id de conversation.
    @Published var decryptedPreviews: [String: String] = [:]

    private let service: MessagesServicing

    init(service: MessagesServicing) {
        self.service = service
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            conversations = .demo
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        if ProcessInfo.processInfo.arguments.contains("--qa-slow-load") {
            try? await Task.sleep(for: .seconds(4))
        }
        do {
            conversations = try await service.conversations()
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Déchiffre les aperçus des derniers messages des conversations E2EE une
    /// fois la clé déverrouillée. Best-effort : un échec laisse le cadenas.
    func decryptPreviews(e2ee: E2EEServicing?) async {
        guard let e2ee, await e2ee.isUnlocked() else { return }
        for conversation in conversations where conversation.e2eeEnabled == true {
            guard let last = conversation.lastMessage, last.isEncrypted,
                  decryptedPreviews[conversation.id] == nil else { continue }
            if let plain = try? await e2ee.decryptText(conversationId: conversation.id, message: last) {
                decryptedPreviews[conversation.id] = plain
            }
        }
    }

    func refreshAfterCreate() async {
        await load()
    }

    /// Marque la conversation comme lue (swipe). Recharge ensuite la liste pour
    /// rafraîchir l'état lu/non-lu.
    func markRead(_ conversation: MessageConversation) async {
        guard let lastMessageId = conversation.lastMessage?.id else { return }
        try? await service.markRead(conversationId: conversation.id, lastMessageId: lastMessageId)
        await load()
    }

    /// Quitte la conversation (swipe) et la retire de la liste localement.
    func leave(_ conversation: MessageConversation) async {
        do {
            try await service.leaveConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MessagesView: View {
    @StateObject private var model: MessagesViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var router: AppRouter
    private let service: MessagesServicing
    private let e2ee: E2EEServicing?
    @State private var showNewConversation = false
    @State private var showE2EEUnlock = false
    @State private var routedConversationId: String?

    init(service: MessagesServicing = MessagesService(api: APIClient()), e2ee: E2EEServicing? = nil) {
        self.service = service
        self.e2ee = e2ee
        _model = StateObject(wrappedValue: MessagesViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                if model.isLoading && model.conversations.isEmpty {
                    ConversationListSkeleton()
                        .sqShimmer()
                        .padding(.vertical, SQSpace.xs)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(model.conversations) { conversation in
                    Button {
                        routedConversationId = conversation.id
                    } label: {
                        HStack(spacing: SQSpace.sm) {
                            conversationRow(conversation)
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: SQSpace.xs) {
                                if let date = conversation.lastMessageAt ?? conversation.updatedAt {
                                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelTertiary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(SQColor.labelTertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await model.markRead(conversation); await services.refreshInboxBadge() }
                        } label: {
                            Label("Lu", systemImage: "checkmark.message")
                        }
                        .tint(SQColor.brandRed)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await model.leave(conversation); await services.refreshInboxBadge() }
                        } label: {
                            Label("Quitter", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            } header: { Text("Conversations") }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(SQColor.danger)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Messages")
        .toolbarTitleInlineCompat()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(SQColor.label)
                }
                .accessibilityLabel("Nouvelle conversation")
            }
        }
        .signalQuestBackground()
        .task {
            if model.conversations.isEmpty { await model.load() }
            await maybePresentE2EEUnlock()
            await model.decryptPreviews(e2ee: e2ee)
            await openRoutedConversationIfNeeded()
        }
        .refreshable {
            await model.load()
            await model.decryptPreviews(e2ee: e2ee)
        }
        .navigationDestinationItemCompat($routedConversationId) { id in
            if let conversation = model.conversations.first(where: { $0.id == id }) {
                ConversationDetailView(conversation: conversation, service: service, e2ee: e2ee)
            }
        }
        .onChangeCompat(of: router.openConversationId) { _, _ in
            Task { await openRoutedConversationIfNeeded() }
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationSheet(service: service) {
                await model.refreshAfterCreate()
            }
        }
        .sheet(isPresented: $showE2EEUnlock) {
            if let e2ee = e2ee, case .authenticated(let user) = session.state {
                E2EEUnlockSheet(userId: user.id, service: e2ee) {
                    Task {
                        await model.load()
                        await model.decryptPreviews(e2ee: e2ee)
                    }
                }
            }
        }
    }

    /// Once the conversation list is loaded, if at least one is E2EE-enabled and
    /// the master key isn't unlocked yet, present the unlock sheet automatically.
    /// After a successful unlock all conversations share the same in-Keychain
    /// private JWK — the per-conversation prompt becomes unnecessary.
    private func maybePresentE2EEUnlock() async {
        guard let e2ee else { return }
        guard model.conversations.contains(where: { $0.e2eeEnabled == true }) else { return }
        let already = await e2ee.isUnlocked()
        if !already && !showE2EEUnlock {
            showE2EEUnlock = true
        }
    }

    /// Opens the conversation requested by a notification tap (via AppRouter),
    /// loading the list first if needed. Falls back to just landing on the
    /// Messages tab when the conversation isn't in the current list.
    private func openRoutedConversationIfNeeded() async {
        guard let id = router.openConversationId else { return }
        router.openConversationId = nil
        if model.conversations.isEmpty { await model.load() }
        if model.conversations.contains(where: { $0.id == id }) {
            routedConversationId = id
        }
    }

    /// Aperçu du dernier message : déchiffré quand la clé E2EE est disponible,
    /// cadenas sinon ; mention explicite pour les pièces jointes.
    private func lastMessagePreview(_ conversation: MessageConversation) -> String {
        guard let last = conversation.lastMessage else {
            return conversation.e2eeEnabled == true ? "Conversation chiffrée" : "Aucun message"
        }
        if last.deletedAt != nil { return "Message supprimé" }
        let attachmentHint = last.attachments.isEmpty ? "" : "📎 "
        if last.isEncrypted {
            if let plain = model.decryptedPreviews[conversation.id], !plain.isEmpty {
                return attachmentHint + plain
            }
            return attachmentHint.isEmpty ? "🔒 Message chiffré" : "🔒 📎 Pièce jointe"
        }
        if let content = last.content, !content.isEmpty {
            return attachmentHint + content
        }
        return last.attachments.isEmpty ? "Aucun message" : "📎 Pièce jointe"
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    /// L'autre participant d'une 1:1 (pour l'avatar/nom), sinon nil (groupe).
    private func otherParticipant(_ conversation: MessageConversation) -> ConversationParticipant? {
        guard !conversation.isGroup else { return nil }
        return conversation.participants.first { $0.userId != currentUserId }
            ?? conversation.participants.first
    }

    private func conversationRow(_ conversation: MessageConversation) -> some View {
        let title = conversation.displayTitle(excluding: currentUserId)
        return HStack(spacing: SQSpace.md) {
            SQAvatar(
                url: conversation.groupPhotoUrl ?? otherParticipant(conversation)?.user.avatarUrl,
                name: title.isEmpty ? "Conversation" : title,
                size: 52
            )
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                if isOnline(conversation) {
                    Circle()
                        .fill(SQColor.brandGreen)
                        .frame(width: 13, height: 13)
                        .overlay { Circle().stroke(SQColor.bg, lineWidth: 2) }
                        .accessibilityLabel("En ligne")
                }
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                HStack(spacing: SQSpace.xs + 2) {
                    Text(title.isEmpty ? "Conversation" : title)
                        .font(SQType.heading)
                        .lineLimit(1)
                    if conversation.e2eeEnabled == true {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(SQColor.brandGreen)
                            .accessibilityLabel("Conversation chiffrée")
                    }
                }
                Text(lastMessagePreview(conversation))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(SQColor.label)
        .padding(.vertical, 6)
    }

    /// Pastille de présence : au moins un autre participant est en ligne.
    private func isOnline(_ conversation: MessageConversation) -> Bool {
        conversation.participants.contains { $0.presence?.isOnline == true }
    }
}

private struct NewConversationSheet: View {
    let service: MessagesServicing
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var title = ""
    @State private var e2ee = true
    @State private var results: [MessageSearchUser] = []
    @State private var selected: [MessageSearchUser] = []
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Groupe") {
                    TextField("Nom du groupe optionnel", text: $title)
                    Toggle("Chiffrement E2EE", isOn: $e2ee)
                }

                if !selected.isEmpty {
                    Section("Participants") {
                        ForEach(selected) { user in
                            HStack {
                                SQAvatar(url: user.avatarUrl, name: user.displayName, size: 34)
                                    .accessibilityHidden(true)
                                Text(user.displayName)
                                Spacer()
                                Button {
                                    selected.removeAll { $0.id == user.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .accessibilityLabel("Retirer \(user.displayName)")
                            }
                        }
                    }
                }

                Section("Recherche") {
                    TextField("Nom, handle ou email", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    ForEach(results.filter { result in !selected.contains(where: { $0.id == result.id }) }) { user in
                        Button {
                            selected.append(user)
                        } label: {
                            HStack {
                                SQAvatar(url: user.avatarUrl, name: user.displayName, size: 34)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(user.displayName)
                                    Text(user.email)
                                        .font(.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(SQColor.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Nouvelle conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.brandOrange)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isBusy ? "Creation..." : "Creer") {
                        Task { await create() }
                    }
                    .disabled(selected.isEmpty || isBusy)
                    .tint(SQColor.brandOrange)
                }
            }
            .onChangeCompat(of: query) { _, _ in
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await search()
                }
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        do {
            results = try await service.searchUsers(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await service.createConversation(
                participantIds: selected.map(\.id),
                title: normalizedTitle.isEmpty ? nil : normalizedTitle,
                e2ee: e2ee
            )
            Haptics.success()
            await onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

extension Array where Element == MessageConversation {
    static var demo: [MessageConversation] {
        [
            MessageConversation(
                id: "demo-conv-1",
                title: "SignalQuest iOS",
                isGroup: false,
                e2eeEnabled: false,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastMessageAt: Date(),
                lastReadAt: nil,
                pinnedAt: nil,
                participants: [
                    ConversationParticipant(
                        userId: "demo-user",
                        role: "member",
                        joinedAt: Date(),
                        lastReadAt: nil,
                        user: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                        presence: SocialPresence(status: "online", customStatus: nil, lastSeenAt: Date(), isOnline: true)
                    )
                ],
                lastMessage: MessageItem.demo.first
            ),
            MessageConversation(
                id: "demo-conv-2",
                title: "Conversation chiffrée",
                isGroup: false,
                e2eeEnabled: true,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastMessageAt: Date(),
                lastReadAt: nil,
                pinnedAt: nil,
                participants: [],
                lastMessage: nil
            )
        ]
    }
}

extension MessageItem {
    static var demo: [MessageItem] {
        [
            MessageItem(
                id: "demo-message-1",
                conversationId: "demo-conv-1",
                senderId: "demo-user",
                kind: "TEXT",
                content: "Tu peux partager un post, une photo ou un speedtest vers cette conversation.",
                e2eeVersion: nil,
                e2eeIvB64: nil,
                e2eeCiphertextB64: nil,
                e2eeAadB64: nil,
                metadata: nil,
                createdAt: Date(),
                editedAt: nil,
                deletedAt: nil,
                replyToId: nil,
                threadReplyCount: 0,
                sender: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                attachments: [],
                reactions: []
            )
        ]
    }
}
