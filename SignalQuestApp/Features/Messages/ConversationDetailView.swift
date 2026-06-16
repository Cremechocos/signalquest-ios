import SwiftUI
import PhotosUI
import UIKit

struct ConversationDetailView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var messages: [MessageItem] = []
    @State private var olderCursor: String?
    @State private var isLoadingOlder = false
    @State private var readReceipts: [ReadReceipt] = []
    @State private var draft = ""
    @State private var replyTarget: MessageItem?
    @State private var editTarget: MessageItem?
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showUnlockSheet = false
    @State private var syncTask: Task<Void, Never>?
    @State private var isE2EEUnlocked = false
    @State private var decryptedMessages: [String: String] = [:]
    @State private var showReportUser = false
    @State private var showGroupSettings = false
    @State private var typingUntil: Date?
    @State private var lastTypingSignal: Date = .distantPast
    /// Borne du dernier sync delta — max des dates créé/édité/supprimé vues.
    @State private var lastSync: Date = .distantPast

    // Messagerie avancée
    @State private var pinnedMessages: [PinnedMessage] = []
    /// Sondages agrégés par id de message porteur, fusionnant la lecture du
    /// metadata et les réponses de /vote /close.
    @State private var pollsByMessageId: [String: MessagePoll] = [:]
    @State private var transcriptions: [String: String] = [:]
    @State private var transcriptionRequested: Set<String> = []
    @State private var scrollTargetId: String?
    @State private var threadTarget: MessageItem?
    @State private var showSearch = false
    @State private var showScheduled = false
    @State private var showReminders = false
    @State private var showSchedulePicker = false
    @State private var showNewPoll = false
    @State private var reminderTarget: MessageItem?

    private var isE2EE: Bool { conversation.e2eeEnabled == true }
    private var canSend: Bool { !isE2EE || isE2EEUnlocked }
    /// L'utilisateur peut-il épingler/désépingler (owner/admin) — le backend
    /// renvoie 403 sinon, on masque donc l'action quand le rôle ne le permet pas.
    private var canPin: Bool {
        guard let uid = currentUserId else { return false }
        guard conversation.isGroup else { return true }
        let role = conversation.participants.first { $0.userId == uid }?.role
        return role == "owner" || role == "admin"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isE2EE && !isE2EEUnlocked {
                Button {
                    showUnlockSheet = true
                } label: {
                    Label("Chiffrée — déverrouille pour lire", systemImage: "lock.shield")
                        .font(SQType.caption.weight(.semibold))
                        .padding(SQSpace.sm + 2)
                        .frame(maxWidth: .infinity)
                        .background(SQColor.warning.opacity(0.18))
                        .foregroundStyle(SQColor.label)
                }
                .buttonStyle(.plain)
            }

            pinnedBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if isLoadingOlder {
                            ProgressView()
                                .tint(SQColor.brandRed)
                                .padding(.vertical, SQSpace.sm)
                        }
                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                                .onAppear {
                                    // Atteinte du plus ancien message visible → charge la page précédente.
                                    if message.id == messages.first?.id {
                                        Task { await loadOlder() }
                                    }
                                }
                        }
                        readReceiptFooter
                        typingIndicator
                        if let errorMessage {
                            ErrorStateView(title: "Messages indisponibles", message: errorMessage) {
                                Task { await load() }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding()
                }
                // On suit le DERNIER id (pas le count) : prepender d'anciens messages
                // ne doit pas refaire défiler vers le bas.
                .onChangeCompat(of: messages.last?.id) { _, _ in
                    if let last = messages.last { withAnimation(SQMotion.standard) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChangeCompat(of: scrollTargetId) { _, target in
                    guard let target else { return }
                    withAnimation(SQMotion.standard) { proxy.scrollTo(target, anchor: .center) }
                    scrollTargetId = nil
                }
            }

            composer
        }
        .navigationTitle(conversationTitle)
        .toolbarTitleInlineCompat()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { startCall(mode: "audio") } label: {
                        Label("Appel audio", systemImage: "phone.fill")
                    }
                    Button { startCall(mode: "video") } label: {
                        Label("Appel vidéo", systemImage: "video.fill")
                    }
                } label: {
                    Image(systemName: "phone.circle").foregroundStyle(SQColor.brandOrange)
                }
                .accessibilityLabel("Appeler")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showSearch = true } label: {
                        Label("Rechercher", systemImage: "magnifyingglass")
                    }
                    Button { showScheduled = true } label: {
                        Label("Messages programmés", systemImage: "clock")
                    }
                    Button { showReminders = true } label: {
                        Label("Rappels", systemImage: "bell")
                    }
                    Divider()
                    if conversation.isGroup {
                        Button { showGroupSettings = true } label: {
                            Label("Réglages du groupe", systemImage: "person.3")
                        }
                    }
                    if otherParticipantId != nil {
                        Button(role: .destructive) { showReportUser = true } label: {
                            Label("Signaler", systemImage: "flag")
                        }
                        Button(role: .destructive) { Task { await blockOther() } } label: {
                            Label("Bloquer", systemImage: "hand.raised")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(SQColor.label)
                }
                .accessibilityLabel("Plus d’options")
            }
        }
        .navigationDestination(isPresented: $showSearch) {
            MessageSearchView(conversation: conversation, service: service, e2ee: e2ee) { messageId in
                handleSearchSelection(messageId)
            }
        }
        .navigationDestination(isPresented: $showScheduled) {
            ScheduledMessagesView(conversation: conversation, service: service, e2ee: e2ee)
        }
        .navigationDestination(isPresented: $showReminders) {
            RemindersView(conversation: conversation, service: service, e2ee: e2ee)
        }
        .sheet(item: $threadTarget) { target in
            ThreadView(parentMessage: target, conversation: conversation, service: service, e2ee: e2ee)
        }
        .sheet(isPresented: $showSchedulePicker) {
            ScheduleMessageSheet(conversation: conversation, service: service, e2ee: e2ee, initialText: draft) {
                Haptics.success()
            }
        }
        .sheet(isPresented: $showNewPoll) {
            NewPollView(conversation: conversation, service: service, e2ee: e2ee) { message, poll in
                // Seed direct du sondage (textes d'options déjà résolus) pour un
                // affichage immédiat, sans dépendre du parsing/déchiffrement du
                // message optimiste.
                pollsByMessageId[message.id] = poll
                messages = Self.normalized(messages + [message])
            }
        }
        .sheet(item: $reminderTarget) { target in
            AddReminderSheet(conversation: conversation, message: target, service: service) {
                Haptics.success()
            }
        }
        .sheet(isPresented: $showReportUser) {
            if let id = otherParticipantId {
                ReportSheet(targetType: "user", targetId: id, service: services.reports)
            }
        }
        .sheet(isPresented: $showGroupSettings) {
            GroupSettingsView(conversation: conversation, service: service, e2ee: e2ee)
        }
        .signalQuestBackground()
        .task {
            await load()
            await markRead()
            await shareKeyIfNeeded()
            await loadPinned()
            startSync()
        }
        .onDisappear { stopSync() }
        .onChangeCompat(of: scenePhase) { _, phase in
            // Le flux SSE ne survit pas à la mise en arrière-plan : on le coupe
            // proprement et on resynchronise au retour.
            if phase == .active {
                startSync()
                Task { await refreshDelta() }
            } else {
                stopSync()
            }
        }
        .sheet(isPresented: $showUnlockSheet) {
            if case .authenticated(let user) = session.state {
                E2EEUnlockSheet(userId: user.id, service: e2ee ?? services.e2ee) {
                    Task {
                        await load()
                        await shareKeyIfNeeded()
                        await loadPinned()
                    }
                }
            }
        }
        .onChangeCompat(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task { await sendAttachment(item: newValue) }
        }
        .onChangeCompat(of: draft) { _, newValue in
            guard !newValue.isEmpty, canSend else { return }
            signalTypingIfNeeded()
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyTarget {
                quoteBar(
                    title: "Répondre à \(replyTarget.sender?.displayName ?? "message")",
                    text: displayedContent(for: replyTarget)
                ) { self.replyTarget = nil }
            }
            if let editTarget {
                quoteBar(title: "Modifier le message", text: displayedContent(for: editTarget)) {
                    self.editTarget = nil
                    draft = ""
                }
            }
            HStack(spacing: SQSpace.sm + 2) {
                Menu {
                    Button { showNewPoll = true } label: {
                        Label("Créer un sondage", systemImage: "chart.bar")
                    }
                    Button { showSchedulePicker = true } label: {
                        Label("Programmer l'envoi", systemImage: "clock")
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 36, height: 36)
                        .background(SQColor.fill, in: Circle())
                        .foregroundStyle(SQColor.label)
                }
                .disabled(!canSend || isSending)
                .accessibilityLabel("Plus d'actions")

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "paperclip")
                        .frame(width: 36, height: 36)
                        .background(SQColor.fill, in: Circle())
                        .foregroundStyle(SQColor.label)
                }
                .disabled(!canSend || isSending)
                .accessibilityLabel("Joindre une photo")

                TextField(canSend ? "Message" : "Chiffrement à déverrouiller", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(SQTextFieldStyle())
                    .disabled(!canSend)

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                        .frame(width: 44, height: 44)
                        .background(SQGradient.signal, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || !canSend)
                .accessibilityLabel(isSending ? "Envoi en cours" : "Envoyer le message")
            }
            .padding()
        }
        .sqGlass(cornerRadius: 0)
    }

    private func quoteBar(title: String, text: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: 2)
                .fill(SQGradient.signal)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.brandOrange)
                Text(text)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(SQColor.labelTertiary)
            }
        }
        .padding(.horizontal)
        .padding(.top, SQSpace.sm)
    }

    // MARK: Bulles

    private func messageBubble(_ message: MessageItem) -> some View {
        let mine = (message.senderId == currentUserId)
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs) {
            VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs + 1) {
                if !mine, let name = message.sender?.displayName {
                    Text(name)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let quoted = quotedMessage(for: message) {
                    HStack(spacing: SQSpace.xs + 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(mine ? Color.white.opacity(0.6) : SQColor.brandOrange)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(quoted.sender?.displayName ?? "Message")
                                .font(SQType.micro)
                            Text(displayedContent(for: quoted))
                                .font(SQType.caption)
                                .lineLimit(2)
                        }
                    }
                    .opacity(0.75)
                    .padding(SQSpace.xs + 2)
                    .background((mine ? Color.white.opacity(0.14) : SQColor.fill.opacity(0.6)), in: RoundedRectangle(cornerRadius: SQRadius.sm))
                }
                attachmentsView(for: message, mine: mine)
                if message.deletedAt != nil {
                    Text("Message supprimé")
                        .font(SQType.caption.italic())
                        .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelTertiary)
                } else if let poll = pollsByMessageId[message.id] {
                    PollBubble(
                        poll: poll,
                        mine: mine,
                        canClose: pollCanClose(poll),
                        onVote: { ids in Task { await vote(messageId: message.id, pollId: poll.pollId, optionIds: ids) } },
                        onClose: { Task { await closePoll(messageId: message.id, pollId: poll.pollId) } }
                    )
                } else {
                    let text = displayedContent(for: message)
                    if !text.isEmpty {
                        Text(text)
                            .font(SQType.body)
                            .foregroundStyle(mine ? .white : SQColor.label)
                    }
                    if let transcription = transcriptions[message.id], !transcription.isEmpty {
                        transcriptionView(transcription, mine: mine)
                    }
                }
                HStack(spacing: SQSpace.xs) {
                    if message.editedAt != nil && message.deletedAt == nil {
                        Text("modifié")
                            .font(SQType.micro)
                            .foregroundStyle(mine ? .white.opacity(0.6) : SQColor.labelTertiary)
                    }
                    if !message.reactions.isEmpty {
                        ForEach(reactionSummaries(for: message)) { reaction in
                            Text("\(reaction.emoji) \(reaction.count)")
                                .font(.caption2)
                                .padding(.horizontal, SQSpace.xs + 2).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay { Capsule().stroke(mine ? Color.white.opacity(0.35) : SQColor.separator, lineWidth: 1) }
                                .foregroundStyle(mine ? .white : SQColor.label)
                        }
                    }
                }
            }
            .padding(SQSpace.md)
            .background(mine ? AnyShapeStyle(SQGradient.signal) : AnyShapeStyle(SQColor.surface), in: bubbleShape(mine: mine))
            .contextMenu { contextMenu(for: message, mine: mine) }
                threadReplyBadge(for: message)
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    /// Indicateur « N réponses » affiché sous une bulle qui a des réponses de
    /// thread. Tappable : ouvre le fil.
    @ViewBuilder
    private func threadReplyBadge(for message: MessageItem) -> some View {
        if let count = message.threadReplyCount, count > 0 {
            Button {
                threadTarget = message
            } label: {
                HStack(spacing: SQSpace.xs) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 9))
                    Text("\(count) réponse\(count > 1 ? "s" : "")")
                        .font(SQType.micro)
                }
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, 4)
                .background(SQColor.surfaceRaised, in: Capsule())
                .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1) }
                .foregroundStyle(SQColor.brandRed)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func transcriptionView(_ text: String, mine: Bool) -> some View {
        HStack(alignment: .top, spacing: SQSpace.xs + 2) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(mine ? .white.opacity(0.75) : SQColor.labelSecondary)
            Text(text)
                .font(SQType.caption.italic())
                .foregroundStyle(mine ? .white.opacity(0.9) : SQColor.labelSecondary)
        }
        .padding(.top, SQSpace.xs)
    }

    /// Coins asymétriques DA : le coin bas côté émetteur est plus petit,
    /// comme une « pointe » de bulle.
    private func bubbleShape(mine: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: SQRadius.xl,
            bottomLeadingRadius: mine ? SQRadius.xl : 6,
            bottomTrailingRadius: mine ? 6 : SQRadius.xl,
            topTrailingRadius: SQRadius.xl,
            style: .continuous
        )
    }

    @ViewBuilder
    private func contextMenu(for message: MessageItem, mine: Bool) -> some View {
        ForEach(["❤️", "🔥", "👏", "🚀", "📡"], id: \.self) { emoji in
            Button(emoji) {
                Task { await toggleReaction(message: message, emoji: emoji) }
            }
        }
        Divider()
        Button {
            editTarget = nil
            replyTarget = message
        } label: {
            Label("Répondre", systemImage: "arrowshape.turn.up.left")
        }
        if message.deletedAt == nil {
            Button {
                threadTarget = message
            } label: {
                Label("Répondre dans un fil", systemImage: "bubble.left.and.bubble.right")
            }
        }
        if message.deletedAt == nil, !displayedContent(for: message).isEmpty {
            Button {
                UIPasteboard.general.string = displayedContent(for: message)
            } label: {
                Label("Copier", systemImage: "doc.on.doc")
            }
        }
        if message.deletedAt == nil {
            Button {
                reminderTarget = message
            } label: {
                Label("Me le rappeler", systemImage: "bell")
            }
            if canPin {
                if isPinned(message) {
                    Button {
                        Task { await unpin(message: message) }
                    } label: {
                        Label("Désépingler", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        Task { await pin(message: message) }
                    } label: {
                        Label("Épingler", systemImage: "pin")
                    }
                }
            }
            if transcriptions[message.id] == nil {
                Button {
                    Task { await requestTranscription(message: message) }
                } label: {
                    Label("Afficher la transcription", systemImage: "waveform")
                }
            }
        }
        if mine && message.deletedAt == nil {
            Button {
                replyTarget = nil
                editTarget = message
                draft = displayedContent(for: message)
            } label: {
                Label("Modifier", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await delete(message: message, forEveryone: true) }
            } label: {
                Label("Supprimer pour tous", systemImage: "trash")
            }
        }
        Button(role: .destructive) {
            Task { await delete(message: message, forEveryone: false) }
        } label: {
            Label("Supprimer pour moi", systemImage: "trash.slash")
        }
        // Blocage par expéditeur dans les groupes (Guideline 1.2) — en 1:1 le
        // blocage est déjà accessible depuis la barre d'outils.
        if !mine, conversation.isGroup, let senderId = message.senderId {
            Divider()
            Button(role: .destructive) {
                Task { await blockSender(userId: senderId) }
            } label: {
                Label("Bloquer l’expéditeur", systemImage: "hand.raised")
            }
        }
    }

    @ViewBuilder
    private func attachmentsView(for message: MessageItem, mine: Bool) -> some View {
        ForEach(message.attachments.filter { $0.url != nil }) { attachment in
            if attachment.kind.uppercased() == "IMAGE" || (attachment.contentType?.hasPrefix("image/") ?? false) {
                AsyncImage(url: attachment.url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Label("Image indisponible", systemImage: "photo")
                            .font(SQType.caption)
                            .padding(SQSpace.md)
                    default:
                        Rectangle().fill(SQColor.fill).sqShimmer()
                    }
                }
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            } else if let url = attachment.url {
                Link(destination: url) {
                    Label(attachment.fileName ?? "Pièce jointe", systemImage: "doc")
                        .font(SQType.caption)
                        .foregroundStyle(mine ? .white : SQColor.label)
                }
            }
        }
    }

    // MARK: Barre d'épinglés

    @ViewBuilder
    private var pinnedBar: some View {
        if let pinned = pinnedMessages.first {
            Button {
                scrollTargetId = pinned.messageId
                Haptics.selection()
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SQColor.brandRed)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pinnedMessages.count > 1 ? "\(pinnedMessages.count) messages épinglés" : "Message épinglé")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                        Text(pinnedSnippet(pinned))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(SQColor.labelTertiary)
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .frame(maxWidth: .infinity)
                .background(SQColor.surface)
                .overlay(alignment: .bottom) { Divider().overlay(SQColor.separator) }
                .overlay(alignment: .leading) {
                    Rectangle().fill(SQColor.brandRed).frame(width: 3)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func pinnedSnippet(_ pinned: PinnedMessage) -> String {
        guard let message = pinned.message else { return "Message" }
        if message.isEncrypted { return decryptedMessages[message.id] ?? "🔒 Message chiffré" }
        let value = message.content ?? ""
        return value.isEmpty ? "Pièce jointe" : value
    }

    @ViewBuilder
    private var readReceiptFooter: some View {
        if let lastMine = messages.last(where: { $0.senderId == currentUserId }),
           let lastDate = lastMine.createdAt {
            let seenBy = readReceipts.filter { receipt in
                receipt.userId != currentUserId && (receipt.lastReadAt ?? .distantPast) >= lastDate
            }
            if !seenBy.isEmpty {
                Text("Vu par \(seenBy.compactMap { $0.name }.joined(separator: ", "))")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if let typingUntil, typingUntil > Date() {
            TypingDotsView()
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm + 2)
                .background(SQColor.surface, in: Capsule())
                .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .accessibilityLabel("En train d’écrire…")
        }
    }

    private func quotedMessage(for message: MessageItem) -> MessageItem? {
        guard let replyToId = message.replyToId else { return nil }
        return messages.first { $0.id == replyToId }
    }

    private func reactionSummaries(for message: MessageItem) -> [MessageReactionSummary] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reaction in message.reactions {
            if counts[reaction.emoji] == nil {
                order.append(reaction.emoji)
            }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.map { MessageReactionSummary(emoji: $0, count: counts[$0, default: 0]) }
    }

    private func displayedContent(for message: MessageItem) -> String {
        if message.deletedAt != nil { return "" }
        if message.isEncrypted { return decryptedMessages[message.id] ?? "🔒 Message chiffré" }
        return message.content ?? ""
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    // MARK: Chargement / sync

    private func load() async {
        if AppEnvironment.usesDemoData {
            messages = conversation.lastMessage.map { [$0] } ?? MessageItem.demo
            errorMessage = nil
            return
        }
        do {
            let page = try await service.messages(conversationId: conversation.id, cursor: nil)
            messages = Self.normalized(page.messages)
            olderCursor = (page.hasMore ?? (page.nextCursor != nil)) ? page.nextCursor : nil
            readReceipts = page.readReceipts ?? []
            errorMessage = nil
            advanceLastSync(with: messages)
            await refreshE2EEState()
            await decryptLoadedMessages()
            refreshPolls()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pagination ascendante : charge la page de messages plus anciens et la
    /// préfixe à la liste (cf. audit COMPLETENESS-04). En cas d'absence de
    /// curseur (début de l'historique atteint), ne fait rien.
    private func loadOlder() async {
        guard !AppEnvironment.usesDemoData, !isLoadingOlder, let cursor = olderCursor else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await service.messages(conversationId: conversation.id, cursor: cursor)
            let known = Set(messages.map(\.id))
            let older = Self.normalized(page.messages).filter { !known.contains($0.id) }
            guard !older.isEmpty else { olderCursor = nil; return }
            messages.insert(contentsOf: older, at: 0)
            olderCursor = (page.hasMore ?? (page.nextCursor != nil)) ? page.nextCursor : nil
            await decryptLoadedMessages()
            refreshPolls()
        } catch {
            // Silencieux : l'historique déjà chargé reste utilisable.
        }
    }

    private func advanceLastSync(with items: [MessageItem]) {
        var bound = lastSync == .distantPast ? Date() : lastSync
        for item in items {
            for date in [item.createdAt, item.editedAt, item.deletedAt].compactMap({ $0 }) where date > bound {
                bound = date
            }
        }
        lastSync = bound
    }

    private func startSync() {
        guard !AppEnvironment.usesDemoData else { return }
        stopSync()
        let engine = MessageSyncEngine(sse: services.sse)
        let conversationId = conversation.id
        MessageSyncLog.logger.debug("startSync \(conversationId, privacy: .public)")
        syncTask = Task {
            for await trigger in engine.refreshEvents(conversationId: conversationId) {
                if Task.isCancelled { return }
                MessageSyncLog.logger.debug("trigger \(String(describing: trigger), privacy: .public)")
                switch trigger {
                case .typingEvent:
                    await MainActor.run {
                        withAnimation(SQMotion.fast) { typingUntil = Date().addingTimeInterval(5) }
                    }
                case .serverEvent, .polling:
                    await refreshDelta()
                }
            }
            MessageSyncLog.logger.debug("sync stream ended \(conversationId, privacy: .public)")
        }
    }

    private func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func refreshDelta() async {
        guard lastSync != .distantPast else {
            await load()
            return
        }
        // Petit recouvrement pour absorber les horloges décalées ; la
        // normalisation dédoublonne par id.
        let since = lastSync.addingTimeInterval(-2)
        do {
            let delta = try await service.messagesDelta(conversationId: conversation.id, since: since)
            guard !delta.isEmpty else { return }
            // Ne réagir qu'aux changements réellement nouveaux : le recouvrement
            // re-renvoie toujours les derniers messages, et markRead déclenche un
            // événement SSE read_state — sans ce garde on boucle indéfiniment.
            let knownIds = Set(messages.map(\.id))
            let knownEditDates = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.editedAt ?? $0.deletedAt ?? .distantPast) })
            let fresh = delta.filter { item in
                !knownIds.contains(item.id) ||
                (item.editedAt ?? item.deletedAt ?? .distantPast) > (knownEditDates[item.id] ?? .distantPast)
            }
            guard !fresh.isEmpty else { return }
            MessageSyncLog.logger.debug("delta since=\(since.ISO8601Format(), privacy: .public) -> \(fresh.count) nouveau(x)")
            await MainActor.run {
                messages = Self.normalized(messages + delta)
                advanceLastSync(with: delta)
            }
            await decryptLoadedMessages()
            refreshPolls()
            await loadPinned()
            await markRead()
        } catch {
            MessageSyncLog.logger.error("delta erreur: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func signalTypingIfNeeded() {
        // Throttle 3 s, comme le composer web.
        guard Date().timeIntervalSince(lastTypingSignal) > 3 else { return }
        lastTypingSignal = Date()
        Task { await service.setTyping(conversationId: conversation.id) }
    }

    // MARK: Messagerie avancée — actions

    private func handleSearchSelection(_ messageId: String) {
        // Si le message est déjà chargé on scrolle directement ; sinon on recharge
        // puis on tente le scroll (cas d'un vieux message hors page courante).
        if messages.contains(where: { $0.id == messageId }) {
            scrollTargetId = messageId
        } else {
            Task {
                await load()
                scrollTargetId = messageId
            }
        }
    }

    private func loadPinned() async {
        guard !AppEnvironment.usesDemoData else { return }
        do {
            pinnedMessages = try await service.pinnedMessages(conversationId: conversation.id)
            await decryptPinnedIfNeeded()
        } catch {
            MessageSyncLog.logger.error("pinned erreur: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decryptPinnedIfNeeded() async {
        guard isE2EE, isE2EEUnlocked, let e2ee else { return }
        for pinned in pinnedMessages {
            guard let message = pinned.message, message.isEncrypted, decryptedMessages[message.id] == nil else { continue }
            decryptedMessages[message.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: message)
        }
    }

    private func isPinned(_ message: MessageItem) -> Bool {
        pinnedMessages.contains { $0.messageId == message.id }
    }

    private func pin(message: MessageItem) async {
        do {
            try await service.pin(conversationId: conversation.id, messageId: message.id)
            await loadPinned()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func unpin(message: MessageItem) async {
        do {
            try await service.unpin(conversationId: conversation.id, messageId: message.id)
            pinnedMessages.removeAll { $0.messageId == message.id }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func requestTranscription(message: MessageItem) async {
        guard !transcriptionRequested.contains(message.id) else { return }
        transcriptionRequested.insert(message.id)
        do {
            if let transcription = try await service.transcription(messageId: message.id),
               let text = transcription.text, !text.isEmpty {
                transcriptions[message.id] = text
            } else {
                errorMessage = "Aucune transcription disponible pour ce message."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Sondages

    /// Construit l'état des sondages à partir du metadata des messages chargés.
    /// Les votes/clôtures effectués via l'API écrasent ensuite cette base. Pour
    /// les conversations chiffrées, fusionne la question/les textes d'options
    /// déchiffrés (le metadata en clair ne porte que les identifiants).
    private func refreshPolls() {
        for message in messages {
            if let existing = pollsByMessageId[message.id] {
                // Un état issu d'un vote/clôture existe déjà : on garde ses
                // compteurs et on réinjecte simplement les textes déchiffrés (E2EE).
                if isE2EE, let decrypted = decryptedMessages[message.id] {
                    pollsByMessageId[message.id] = existing.mergingDecryptedTexts(decrypted)
                }
                continue
            }
            guard let metadata = PollMetadata.parse(fromMetadataJSON: message.metadata) else { continue }
            var poll = metadata.toPoll(currentUserId: currentUserId)
            if isE2EE, let decrypted = decryptedMessages[message.id] {
                poll = poll.mergingDecryptedTexts(decrypted)
            }
            pollsByMessageId[message.id] = poll
        }
    }

    private func pollCanClose(_ poll: MessagePoll) -> Bool {
        guard let uid = currentUserId else { return false }
        if poll.createdById == uid { return true }
        // Owner/admin de groupe peuvent aussi clôturer (cf. route close).
        guard conversation.isGroup else { return false }
        let role = conversation.participants.first { $0.userId == uid }?.role
        return role == "owner" || role == "admin"
    }

    private func vote(messageId: String, pollId: String, optionIds: [String]) async {
        do {
            let updated = try await service.votePoll(pollId: pollId, optionIds: optionIds)
            pollsByMessageId[messageId] = mergePollTexts(updated, messageId: messageId)
            Haptics.selection()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func closePoll(messageId: String, pollId: String) async {
        do {
            let updated = try await service.closePoll(pollId: pollId)
            pollsByMessageId[messageId] = mergePollTexts(updated, messageId: messageId)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Réinjecte les textes déchiffrés (question/options) dans une réponse de
    /// vote/clôture pour les conversations chiffrées, où le serveur ne renvoie
    /// que les identifiants d'options.
    private func mergePollTexts(_ poll: MessagePoll, messageId: String) -> MessagePoll {
        guard isE2EE, let decrypted = decryptedMessages[messageId] else { return poll }
        return poll.mergingDecryptedTexts(decrypted)
    }

    // MARK: Actions

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            if let editTarget {
                try await service.editMessage(messageId: editTarget.id, text: text, in: conversation, e2ee: e2ee)
                decryptedMessages[editTarget.id] = text
                self.editTarget = nil
                draft = ""
                await load()
            } else {
                let sent = try await service.sendText(text, in: conversation, replyToId: replyTarget?.id, e2ee: e2ee)
                messages = Self.normalized(messages + [sent])
                if sent.isEncrypted {
                    decryptedMessages[sent.id] = text
                }
                replyTarget = nil
                draft = ""
            }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func sendAttachment(item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        isSending = true
        defer { isSending = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else { return }
            guard let prepared = Self.preparedJPEG(from: raw) else {
                throw E2EEError.unsupported("Image illisible")
            }
            let uploaded = try await service.uploadAttachment(
                conversationId: conversation.id,
                data: prepared.data,
                filename: "photo.jpg",
                mimeType: "image/jpeg"
            )
            let attachment = UploadedAttachment(
                kind: "IMAGE",
                url: uploaded.url,
                fileName: uploaded.fileName ?? "photo.jpg",
                contentType: uploaded.contentType ?? "image/jpeg",
                size: uploaded.size ?? prepared.data.count,
                width: uploaded.width ?? prepared.width,
                height: uploaded.height ?? prepared.height
            )
            let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let sent = try await service.sendAttachments(
                [attachment],
                caption: caption,
                in: conversation,
                replyToId: replyTarget?.id,
                e2ee: e2ee
            )
            messages = Self.normalized(messages + [sent])
            if sent.isEncrypted, !caption.isEmpty {
                decryptedMessages[sent.id] = caption
            }
            draft = ""
            replyTarget = nil
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Recompresse l'image en JPEG ≤ 1280 px qualité 0,85 (HEIC converti
    /// d'office) — même normalisation qu'Android avant upload.
    private static func preparedJPEG(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1280
        let largest = max(image.size.width, image.size.height)
        let scale = largest > maxSide ? maxSide / largest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return (jpeg, Int(target.width), Int(target.height))
    }

    private func toggleReaction(message: MessageItem, emoji: String) async {
        let alreadyMine = message.reactions.contains { $0.emoji == emoji && $0.userId == currentUserId }
        do {
            if alreadyMine {
                try await service.removeReaction(messageId: message.id, emoji: emoji)
            } else {
                try await service.react(messageId: message.id, emoji: emoji)
            }
            await refreshDelta()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(message: MessageItem, forEveryone: Bool) async {
        do {
            try await service.deleteMessage(messageId: message.id, forEveryone: forEveryone)
            if forEveryone {
                await load()
            } else {
                messages.removeAll { $0.id == message.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markRead() async {
        guard let last = messages.last else { return }
        try? await service.markRead(conversationId: conversation.id, lastMessageId: last.id)
    }

    private func shareKeyIfNeeded() async {
        guard isE2EE, isE2EEUnlocked, let e2ee else { return }
        await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
    }

    /// Titre de la conversation sans inclure l'utilisateur courant.
    private var conversationTitle: String {
        let title = conversation.displayTitle(excluding: currentUserId)
        return title.isEmpty ? "Conversation" : title
    }

    private func startCall(mode: String) {
        services.callManager.startOutgoingCall(conversationId: conversation.id, mode: mode, displayName: conversationTitle)
    }

    private var otherParticipantId: String? {
        guard !conversation.isGroup else { return nil }
        return conversation.participants.map(\.userId).first { $0 != currentUserId }
    }

    private func blockOther() async {
        guard let id = otherParticipantId else { return }
        do {
            try await services.friends.block(userId: id)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Bloque l'expéditeur d'un message de groupe (Guideline 1.2).
    private func blockSender(userId: String) async {
        do {
            try await services.friends.block(userId: userId)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func refreshE2EEState() async {
        guard isE2EE, let e2ee else {
            isE2EEUnlocked = !isE2EE
            return
        }
        isE2EEUnlocked = await e2ee.isConversationUnlocked(conversationId: conversation.id)
    }

    private func decryptLoadedMessages() async {
        guard isE2EE, isE2EEUnlocked, let e2ee else {
            MessageSyncLog.logger.debug("decrypt skip e2ee=\(isE2EE) unlocked=\(isE2EEUnlocked)")
            return
        }
        for message in messages where message.isEncrypted && decryptedMessages[message.id] == nil {
            do {
                decryptedMessages[message.id] = try await e2ee.decryptText(conversationId: conversation.id, message: message)
            } catch {
                MessageSyncLog.logger.error("decrypt \(message.id, privacy: .public) erreur: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// De-duplicates messages by id (latest copy wins, original position kept for
    /// stable ordering) and sorts chronologically by createdAt. Prevents the
    /// delta sync and optimistic sends from creating duplicates or reordering.
    private static func normalized(_ items: [MessageItem]) -> [MessageItem] {
        var byId: [String: (order: Int, item: MessageItem)] = [:]
        var nextOrder = 0
        for item in items {
            if let existing = byId[item.id] {
                byId[item.id] = (existing.order, item)
            } else {
                byId[item.id] = (nextOrder, item)
                nextOrder += 1
            }
        }
        return byId.values
            .sorted { lhs, rhs in
                switch (lhs.item.createdAt, rhs.item.createdAt) {
                case let (l?, r?): return l == r ? lhs.order < rhs.order : l < r
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): return lhs.order < rhs.order
                }
            }
            .map(\.item)
    }
}

private struct MessageReactionSummary: Identifiable {
    let emoji: String
    let count: Int

    var id: String { emoji }
}

/// Trois points qui ondulent doucement (indicateur « en train d'écrire »).
/// Avec Reduce Motion, les points restent statiques.
private struct TypingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(time: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                dots(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(time: TimeInterval?) -> some View {
        HStack(spacing: SQSpace.xs + 1) {
            ForEach(0..<3, id: \.self) { index in
                let phase: Double = time.map { sin(($0 * 2 * .pi / 1.2) - Double(index) * 0.85) } ?? 0
                Circle()
                    .fill(SQColor.labelSecondary)
                    .frame(width: 6, height: 6)
                    .offset(y: CGFloat(phase) * -2.5)
                    .opacity(0.45 + 0.55 * max(0, phase))
            }
        }
    }
}
