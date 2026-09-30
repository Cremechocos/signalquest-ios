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
            conversations = Array.demo.inDisplayOrder()
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        if AppEnvironment.delaysLoadForQA {
            try? await Task.sleep(for: .seconds(4))
        }
        do {
            conversations = try await service.conversations().inDisplayOrder()
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

    /// Marque la conversation comme lue (balayage ou appui long). L'état change
    /// tout de suite et revient si le serveur refuse.
    func markRead(_ conversation: MessageConversation) async {
        guard let lastMessageId = conversation.lastMessage?.id else { return }
        let previous = conversation.lastReadAt
        update(conversation.id) { $0.with(lastReadAt: conversation.lastMessageAt ?? Date()) }
        do {
            try await service.markRead(conversationId: conversation.id, lastMessageId: lastMessageId)
        } catch {
            update(conversation.id) { $0.with(lastReadAt: previous) }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Remet en non lu (plan 3, vague 2) : le serveur ramène la lecture au tout
    /// début, la pastille et le badge reviennent.
    func markUnread(_ conversation: MessageConversation) async {
        let previous = conversation.lastReadAt
        update(conversation.id) { $0.with(lastReadAt: Date(timeIntervalSince1970: 0)) }
        do {
            try await service.markUnread(conversationId: conversation.id)
        } catch {
            update(conversation.id) { $0.with(lastReadAt: previous) }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Épingle ou désépingle (plan 3, vague 2) : les épinglées passent en tête.
    func setPinned(_ pinned: Bool, _ conversation: MessageConversation) async {
        let previous = conversation.pinnedAt
        update(conversation.id) { $0.with(pinnedAt: pinned ? Date() : nil) }
        do {
            _ = try await service.setConversationPinned(pinned, conversationId: conversation.id)
        } catch {
            update(conversation.id) { $0.with(pinnedAt: previous) }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Change une conversation, puis remet la liste dans son ordre d'affichage.
    private func update(_ id: String, _ transform: (MessageConversation) -> MessageConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var updated = conversations
        updated[index] = transform(updated[index])
        withAnimation(SQMotion.resolve(SQMotion.standard, UIAccessibility.isReduceMotionEnabled)) {
            conversations = updated.inDisplayOrder()
        }
    }

    /// Quitte la conversation (swipe) et la retire de la liste localement.
    func leave(_ conversation: MessageConversation) async {
        do {
            try await service.leaveConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}

struct MessagesView: View {
    @StateObject private var model: MessagesViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    private let service: MessagesServicing
    private let e2ee: E2EEServicing?
    @State private var showNewConversation = false
    @State private var showE2EEUnlock = false
    @State private var routedConversationId: String?
    /// Quitter se confirme : le balayage suffisait à perdre la conversation (SOC-22).
    @State private var pendingLeave: MessageConversation?
    /// Brouillons par conversation, lus sur l'appareil (plan 3, vague 1).
    @State private var drafts: [String: String] = [:]

    /// Insets des rangées : gap vertical de 14 pt entre cartes (2 × 7),
    /// marge d'écran 20 pt.
    private var cardRowInsets: EdgeInsets {
        EdgeInsets(top: 7, leading: SQSpace.xl, bottom: 7, trailing: SQSpace.xl)
    }

    init(service: MessagesServicing, e2ee: E2EEServicing? = nil) {
        self.service = service
        self.e2ee = e2ee
        _model = StateObject(wrappedValue: MessagesViewModel(service: service))
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                if E2EEV2RuntimeReadGate.enabled {
                    E2EEV2NotificationPreviewNotice()
                }
            }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: SQSpace.xl, bottom: SQSpace.sm, trailing: SQSpace.xl))

            if model.isLoading && model.conversations.isEmpty {
                ConversationListSkeleton()
                    .sqShimmer()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(cardRowInsets)
            }
            ForEach(model.conversations) { conversation in
                Button {
                    routedConversationId = conversation.id
                } label: {
                    conversationCard(conversation)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(cardRowInsets)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if isUnread(conversation) {
                        Button { setRead(true, conversation) } label: {
                            Label("Lu", systemImage: "checkmark.message")
                        }
                        .tint(SQColor.brandRed)
                    } else if conversation.canMarkUnread(currentUserId: currentUserId) {
                        Button { setRead(false, conversation) } label: {
                            Label("Non lu", systemImage: "message.badge")
                        }
                        .tint(SQColor.brandRed)
                    }
                    pinButton(conversation)
                        .tint(SQColor.info)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingLeave = conversation
                    } label: {
                        Label("Quitter", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                // Mêmes actions à l'appui long, et au clic secondaire sur iPad.
                .contextMenu {
                    pinButton(conversation)
                    if isUnread(conversation) {
                        Button { setRead(true, conversation) } label: {
                            Label("Marquer comme lu", systemImage: "checkmark.message")
                        }
                    } else if conversation.canMarkUnread(currentUserId: currentUserId) {
                        Button { setRead(false, conversation) } label: {
                            Label("Marquer comme non lu", systemImage: "message.badge")
                        }
                    }
                    Button(role: .destructive) {
                        pendingLeave = conversation
                    } label: {
                        Label("Quitter", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            if !model.isLoading && model.conversations.isEmpty && model.errorMessage == nil {
                EmptyStateView(
                    title: "Aucune conversation",
                    message: "Démarre une discussion avec un membre de la communauté.",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let error = model.errorMessage {
                // Pattern maison (titre + message + « Réessayer ») au lieu d'une ligne
                // rouge brute peu visible et sans action de relance (INT-09).
                ErrorStateView(title: "Messagerie indisponible", message: error) {
                    Task { await model.load() }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(cardRowInsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        // Comme la conversation : balayage retour rétabli malgré la barre
        // masquée (SOC-30).
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task {
            await reloadDrafts()
            if model.conversations.isEmpty { await model.load() }
            await maybePresentE2EEUnlock()
            openNewConversationIfRequested()
            await model.decryptPreviews(e2ee: e2ee)
            await openRoutedConversationIfNeeded()
        }
        // Au retour d'une conversation : la liste restait figée jusqu'au
        // tirer-pour-rafraîchir (SOC-23). Le premier affichage passe par `.task`.
        .onAppear {
            guard !model.conversations.isEmpty else { return }
            Task {
                await model.load()
                await model.decryptPreviews(e2ee: e2ee)
                await services.refreshInboxBadge(force: true)
            }
        }
        .refreshable {
            await model.load()
            await model.decryptPreviews(e2ee: e2ee)
        }
        .onReceive(NotificationCenter.default.publisher(for: MessageDraftStore.didChange)) { _ in
            Task { await reloadDrafts() }
        }
        .confirmationDialog(
            "Quitter cette conversation ?",
            isPresented: Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } }),
            titleVisibility: .visible,
            presenting: pendingLeave
        ) { conversation in
            Button("Quitter", role: .destructive) {
                pendingLeave = nil
                Task { await model.leave(conversation); await services.refreshInboxBadge(force: true) }
            }
            Button("Annuler", role: .cancel) { pendingLeave = nil }
        } message: { _ in
            Text("Elle disparaîtra de ta liste et tu ne recevras plus ses messages.")
        }
        .navigationDestinationItemCompat($routedConversationId) { id in
            if let conversation = model.conversations.first(where: { $0.id == id }) {
                ConversationDetailView(conversation: conversation, service: service, e2ee: e2ee)
            }
        }
        .onChangeCompat(of: router.openConversationId) { _, _ in
            Task { await openRoutedConversationIfNeeded() }
        }
        .onChangeCompat(of: router.openNewConversation) { _, requested in
            if requested { openNewConversationIfRequested() }
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationSheet(service: service) {
                await model.refreshAfterCreate()
            }
        }
        .sheet(isPresented: $showE2EEUnlock, onDismiss: openNewConversationIfRequested) {
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
        guard let e2ee, !Self.unlockOffered else { return }
        guard model.conversations.contains(where: { $0.e2eeEnabled == true }) else { return }
        let already = await e2ee.isUnlocked()
        if !already && !showE2EEUnlock {
            // Une fois par lancement : la feuille revenait à chaque retour sur
            // la liste (SOC-23). Le bandeau d'une conversation chiffrée reste là.
            Self.unlockOffered = true
            showE2EEUnlock = true
        }
    }

    @MainActor private static var unlockOffered = false

    /// Opens the conversation requested by a notification tap (via AppRouter),
    /// loading the list first if needed. Falls back to just landing on the
    /// Messages tab when the conversation isn't in the current list.
    private func openRoutedConversationIfNeeded() async {
        guard let id = router.openConversationId else { return }
        router.openConversationId = nil
        // Recharger si la liste est vide OU si le fil ciblé n'y est pas encore : le
        // cas fréquent d'une notification pour un NOUVEAU fil (premier message d'un
        // nouveau contact) échouait sinon en silence (UXP-10).
        if model.conversations.isEmpty || !model.conversations.contains(where: { $0.id == id }) {
            await model.load()
        }
        if model.conversations.contains(where: { $0.id == id }) {
            routedConversationId = id
        }
    }

    /// ⌘N sur iPad : la messagerie s'ouvre sur une nouvelle conversation, une
    /// fois l'éventuel déverrouillage du chiffrement passé.
    private func openNewConversationIfRequested() {
        guard router.openNewConversation, !showE2EEUnlock else { return }
        router.openNewConversation = false
        showNewConversation = true
    }

    /// En-tête custom (pas de gros titre nav système) : retour 40 pt circulaire,
    /// titre Bricolage 24, composer 40 pt.
    private var header: some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 40, height: 40)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Retour")

            Text("Messages")
                .font(SQFont.display(24, .bold))
                .foregroundStyle(SQColor.label)

            Spacer(minLength: SQSpace.sm)

            Button {
                Haptics.light()
                showNewConversation = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 40, height: 40)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Nouvelle conversation")
        }
    }

    /// Aperçu du dernier message : déchiffré quand la clé E2EE est disponible,
    /// cadenas sinon ; mention explicite pour les pièces jointes. Le cadenas des
    /// conversations chiffrées est rendu en icône (12 pt) devant l'aperçu.
    /// Les replis passent par `String(localized:)` : rendus en `Text(String)`,
    /// ils restaient en français dans l'app anglaise.
    private func lastMessagePreview(_ conversation: MessageConversation) -> String {
        guard let last = conversation.lastMessage else {
            return conversation.e2eeEnabled == true
                ? String(localized: "Conversation chiffrée")
                : String(localized: "Aucun message")
        }
        if last.deletedAt != nil { return String(localized: "Message supprimé") }
        let attachmentHint = last.attachments.isEmpty ? "" : "📎 "
        if last.isEncrypted {
            if let plain = model.decryptedPreviews[conversation.id], !plain.isEmpty {
                return attachmentHint + plain
            }
            return attachmentHint.isEmpty ? String(localized: "Message chiffré") : String(localized: "📎 Pièce jointe")
        }
        if let content = last.content, !content.isEmpty {
            return attachmentHint + content
        }
        return last.attachments.isEmpty ? String(localized: "Aucun message") : String(localized: "📎 Pièce jointe")
    }

    private func reloadDrafts() async {
        drafts = await MessageDraftStore.shared.all(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
    }

    /// « Brouillon · … » à la place du dernier message, comme dans les
    /// messageries courantes : on retrouve ce qu'on avait commencé.
    private func draftPreview(_ draft: String) -> some View {
        (Text("Brouillon").foregroundColor(SQColor.accentInk)
            + Text(verbatim: " · " + draft.replacingOccurrences(of: "\n", with: " ")))
            .font(SQFont.body(13.5))
            .foregroundStyle(SQColor.labelSecondary)
            .lineLimit(1)
            .accessibilityIdentifier("messages.row.draft")
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

    /// Carte de conversation (rayon 22, fond surface, ombre carte) : avatar 52,
    /// nom Figtree 600 16, aperçu 13.5 (encre + medium si non-lu), heure à droite
    /// (accent si non-lu) + pastille non-lu accent.
    private func conversationCard(_ conversation: MessageConversation) -> some View {
        let unread = isUnread(conversation)
        let title = conversation.displayTitle(excluding: currentUserId)
        return HStack(spacing: SQSpace.md + 1) {
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
                        .overlay { Circle().stroke(SQColor.surface, lineWidth: 2) }
                        .accessibilityLabel("En ligne")
                }
            }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                HStack(spacing: 5) {
                    Text(title.isEmpty ? "Conversation" : title)
                        .font(SQFont.body(16, .semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .accessibilityIdentifier("messages.row.title")
                    // Badges de l'interlocuteur, comme dans le fil.
                    SQUserBadges(badges: conversation.otherParticipantBadges(excluding: currentUserId), size: 12)
                }
                HStack(spacing: SQSpace.xs + 1) {
                    if conversation.e2eeEnabled == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(unread ? SQColor.label : SQColor.labelSecondary)
                            .accessibilityLabel("Conversation chiffrée")
                    }
                    if let draft = drafts[conversation.id] {
                        draftPreview(draft)
                    } else {
                        Text(lastMessagePreview(conversation))
                            .font(unread ? SQFont.body(13.5, .medium) : SQFont.body(13.5))
                            .foregroundStyle(unread ? SQColor.label : SQColor.labelSecondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("messages.row.preview")
                    }
                }
            }
            Spacer(minLength: SQSpace.sm)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 4) {
                    if conversation.pinnedAt != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityLabel("Épinglée")
                            .accessibilityIdentifier("messages.row.pinned")
                    }
                    if let date = conversation.listDate {
                        // `accentInk` : la brique n'est garantie que pour le grand texte.
                        Text(verbatim: ConversationListDate.label(for: date))
                            .font(SQFont.body(12, .medium))
                            .foregroundStyle(unread ? SQColor.accentInk : SQColor.labelSecondary)
                            .accessibilityIdentifier("messages.row.date")
                    }
                }
                if unread {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Non lu")
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, SQSpace.lg)
        .sqCardBackground()
        .contentShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
    }

    private func pinButton(_ conversation: MessageConversation) -> some View {
        let pinned = conversation.pinnedAt != nil
        return Button {
            Haptics.light()
            Task { await model.setPinned(!pinned, conversation) }
        } label: {
            Label(pinned ? "Désépingler" : "Épingler", systemImage: pinned ? "pin.slash" : "pin")
        }
    }

    private func setRead(_ read: Bool, _ conversation: MessageConversation) {
        Task {
            if read { await model.markRead(conversation) } else { await model.markUnread(conversation) }
            await services.refreshInboxBadge(force: true)
        }
    }

    /// Pastille de présence : au moins un autre participant est en ligne.
    private func isOnline(_ conversation: MessageConversation) -> Bool {
        conversation.participants.contains { $0.presence?.isOnline == true }
    }

    /// Conversation non lue (MSG-UX-02) : dernier message reçu d'un autre, postérieur
    /// au marqueur de lecture courant.
    private func isUnread(_ conversation: MessageConversation) -> Bool {
        conversation.isUnread(currentUserId: currentUserId)
    }
}

private struct NewConversationSheet: View {
    let service: MessagesServicing
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var title = ""
    @State private var e2ee = true
    @State private var results: [MessageSearchUser] = []
    @State private var selected: [MessageSearchUser] = []
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Nom du groupe optionnel", text: $title)
                    Toggle(isOn: $e2ee) {
                        HStack(spacing: SQSpace.xs) {
                            Text("Conversation chiffrée")
                            SQInfoButton(term: .endToEndEncryption)
                        }
                    }
                } header: {
                    Text("Groupe")
                } footer: {
                    // La limite se dit AVANT de créer : on la découvrait au premier
                    // envoi de photo refusé (SOC-07).
                    if e2ee {
                        Text("Pour l’instant, une conversation chiffrée n’accepte que du texte : ni photo, ni vocal, ni sondage, ni réaction, ni appel.")
                    }
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
                                    if let subtitle = user.publicSubtitle {
                                        Text(verbatim: subtitle)
                                            .font(.caption)
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
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
                    Button("Annuler") { dismiss() }.tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isBusy ? "Création…" : "Créer") {
                        Task { await create() }
                    }
                    .disabled(selected.isEmpty || isBusy)
                    .tint(SQColor.brandRed)
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
            errorMessage = error.userFacingMessage
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
            errorMessage = error.userFacingMessage
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
                // Une heure plus tôt : la liste se trie par date affichée.
                lastMessageAt: Date().addingTimeInterval(-3_600),
                lastReadAt: nil,
                pinnedAt: nil,
                // Deux personnes, comme une vraie conversation chiffrée : sans
                // elles, « Appeler » s'arrête sur « Aucun autre participant ».
                participants: [
                    ConversationParticipant(
                        userId: "mock-user",
                        role: "member",
                        joinedAt: Date(),
                        lastReadAt: nil,
                        user: MessageUser(id: "mock-user", name: "SignalQuest iOS", email: "ios@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user-2",
                        role: "member",
                        joinedAt: Date(),
                        lastReadAt: nil,
                        user: MessageUser(id: "demo-user-2", name: "Léa", email: "lea@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    )
                ],
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

/// Date d'une conversation dans la liste, comme les messageries : l'heure
/// aujourd'hui, « Hier », le jour de la semaine, puis la date. « il y a 2 m. »
/// se lisait minutes ou mois (UI-12).
enum ConversationListDate {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Hier")
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return date.formatted(.dateTime.weekday(.wide).locale(locale))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
}
