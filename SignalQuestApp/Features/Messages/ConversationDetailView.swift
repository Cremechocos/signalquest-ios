import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import CoreLocation

struct ConversationDetailView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    /// Masque le dock flottant global le temps de la conversation
    /// (router.isDockHidden, cf. spec Messages).
    @EnvironmentObject private var router: AppRouter
    /// Injecté à la racine (RootView) — observé ici pour griser l'appel hors-ligne
    /// (CALL-OFFLINE-21). On ne lit PAS services.networkPath (simple `let`, ne
    /// déclenche pas de re-render) : l'EnvironmentObject suit bien le @Published.
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [MessageItem] = []
    @State private var olderCursor: String?
    @State private var isLoadingOlder = false
    @State private var readReceipts: [ReadReceipt] = []
    // PERF-MSG-01 : le texte saisi vit dans `MessageComposerBar` (sous-vue) pour que la
    // frappe n'invalide plus le corps de cette vue (et donc la liste des messages) à
    // chaque caractère. Le parent y POUSSE du texte (pré-remplissage édition, vidage
    // après envoi) via ce couple seed/token, et REÇOIT le texte courant via closures.
    @State private var composerSeed = ""
    @State private var composerSeedToken = 0
    @State private var scheduleSeedText = ""
    @State private var replyTarget: MessageItem?
    @State private var editTarget: MessageItem?
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var showUnlockSheet = false
    @State private var syncTask: Task<Void, Never>?
    @State private var isE2EEUnlocked = false
    @State private var decryptedMessages: [String: String] = [:]
    /// MSG-API-01 — statut d'envoi optimiste, indexé par id LOCAL de bulle.
    /// Absent = message confirmé (rendu normal). `.sending` pendant l'appel
    /// réseau, `.failed` si l'envoi échoue (la bulle est conservée + action
    /// « Réessayer » au tap).
    @State private var sendStatus: [String: MessageSendStatus] = [:]
    /// Données pour rejouer un envoi échoué sans doublon : la même
    /// Idempotency-Key est réutilisée d'une tentative à l'autre.
    @State private var pendingSends: [String: PendingSend] = [:]
    /// E2EE-UX-04 — vrai quand une rotation de clé (staleKey/409) a été détectée :
    /// affiche un bandeau « appuie pour resynchroniser » au lieu de bulles muettes.
    @State private var needsKeyResync = false
    @State private var isResyncingKey = false
    @State private var showReportUser = false
    @State private var showGroupSettings = false
    @State private var typingUntil: Date?
    @State private var lastTypingSignal: Date = .distantPast
    /// Borne du dernier sync delta — max des dates créé/édité/supprimé vues.
    @State private var lastSync: Date = .distantPast
    /// Présence « actif sur la conversation » : ids des participants regardant la conv.
    @State private var conversationViewers: [String] = []
    @State private var activePingTask: Task<Void, Never>?

    // Messagerie avancée
    @State private var pinnedMessages: [PinnedMessage] = []
    /// Sondages agrégés par id de message porteur, fusionnant la lecture du
    /// metadata et les réponses de /vote /close.
    @State private var pollsByMessageId: [String: MessagePoll] = [:]
    @State private var transcriptions: [String: String] = [:]
    @State private var transcriptionRequested: Set<String> = []
    @State private var scrollTargetId: String?
    /// Message momentanément surligné après un saut vers une citation (~850 ms).
    @State private var highlightedMessageId: String?
    /// MSG-FLUIDITY-01 — id du message qui était en tête AVANT un prepend ; sert
    /// à réancrer le scroll dessus (sans animation) pour figer la position de
    /// lecture quand on charge des messages plus anciens.
    @State private var prependAnchorId: String?
    @State private var threadTarget: MessageItem?
    @State private var showSearch = false
    @State private var showScheduled = false
    @State private var showReminders = false
    @State private var showSaved = false
    /// Messages éphémères (parité Android) : quand actif, les textes envoyés
    /// portent un TTL de 24 h (le backend pose `expiresAt`).
    @State private var ephemeralEnabled = false
    @State private var isSharingLocation = false
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
            topBar

            if isE2EE && !isE2EEUnlocked {
                Button {
                    showUnlockSheet = true
                } label: {
                    Label("Chiffrée — déverrouille pour lire", systemImage: "lock.shield")
                        .font(SQType.caption.weight(.semibold))
                        .padding(SQSpace.sm + 2)
                        .frame(maxWidth: .infinity)
                        .background(SQColor.warningSoft)
                        .foregroundStyle(SQColor.label)
                }
                .buttonStyle(.plain)
            } else if needsKeyResync {
                // E2EE-UX-04 : la clé a tourné côté autre plateforme.
                Button {
                    Haptics.medium()
                    Task { await resyncKey() }
                } label: {
                    Label(
                        isResyncingKey ? "Resynchronisation…" : "Clé mise à jour — appuie pour resynchroniser",
                        systemImage: isResyncingKey ? "arrow.triangle.2.circlepath" : "key.viewfinder"
                    )
                    .font(SQType.caption.weight(.semibold))
                    .padding(SQSpace.sm + 2)
                    .frame(maxWidth: .infinity)
                    .background(SQColor.warningSoft)
                    .foregroundStyle(SQColor.label)
                }
                .buttonStyle(.plain)
                .disabled(isResyncingKey)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            pinnedBar

            if otherIsViewing {
                Text("Actif sur la conversation")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.brandRed)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
                    .transition(.opacity)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // MSG-FLUIDITY-02 — Sentinelle de pagination en tête de liste :
                        // se déclenche quand le haut de l'historique devient visible.
                        // Plus fiable que l'onAppear du premier message (qui se
                        // redéclenchait à chaque insertion). Le garde isLoadingOlder
                        // + olderCursor (dans loadOlder) évite les appels en doublon.
                        if olderCursor != nil {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { Task { await loadOlder() } }
                        }
                        if isLoadingOlder {
                            ProgressView()
                                .tint(SQColor.brandRed)
                                .padding(.vertical, SQSpace.sm)
                        }
                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                                .background(
                                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                        .fill(SQColor.brandRed.opacity(highlightedMessageId == message.id ? 0.14 : 0))
                                )
                                .animation(SQMotion.standard, value: highlightedMessageId)
                        }
                        readReceiptFooter
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
                // MSG-FLUIDITY-01 — Réancre sur le message qui était en tête avant
                // le prepend, SANS animation, pour que charger d'anciens messages ne
                // fasse pas « sauter » la position de lecture.
                .onChangeCompat(of: prependAnchorId) { _, anchor in
                    guard let anchor else { return }
                    proxy.scrollTo(anchor, anchor: .top)
                    prependAnchorId = nil
                }
                .onChangeCompat(of: scrollTargetId) { _, target in
                    guard let target else { return }
                    withAnimation(SQMotion.standard) { proxy.scrollTo(target, anchor: .center) }
                    scrollTargetId = nil
                }
            }

            // Frappe : ligne compacte épinglée juste au-dessus du composer (parité
            // Android — auparavant dans l'en-tête, désormais en bas de conversation).
            typingIndicator
                .padding(.horizontal)
            composer
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
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
            ScheduleMessageSheet(conversation: conversation, service: service, e2ee: e2ee, initialText: scheduleSeedText) {
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
        .sheet(isPresented: $showSaved) {
            SavedMessagesView(service: service, currentUserId: currentUserId)
        }
        .signalQuestBackground()
        .onAppear {
            // Le dock flottant global est masqué le temps de la conversation.
            router.isDockHidden = true
        }
        .task {
            await load()
            await markRead()
            await shareKeyIfNeeded()
            await loadPinned()
            startSync()
            startActivePing()
        }
        .onDisappear {
            router.isDockHidden = false
            stopSync()
            stopActivePing(sendLeave: true)
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            // Le flux SSE ne survit pas à la mise en arrière-plan : on le coupe
            // proprement et on resynchronise au retour.
            if phase == .active {
                startSync()
                startActivePing()
                Task { await refreshDelta() }
            } else {
                stopSync()
                stopActivePing(sendLeave: true)
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
    }

    // MARK: Barre haute

    /// Barre haute custom (glass) : retour 38 pt, avatar 42, nom + « en ligne »,
    /// appel + menu d'options — remplace la barre de navigation système.
    private var topBar: some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 38, height: 38)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Retour")

            SQAvatar(
                url: conversation.groupPhotoUrl ?? otherParticipantAvatarURL,
                name: conversationTitle,
                size: 42
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(conversationTitle)
                    .font(SQFont.body(16, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                if otherIsOnline {
                    Text("en ligne")
                        .font(SQFont.body(12))
                        .foregroundStyle(SQColor.success)
                }
            }

            Spacer(minLength: SQSpace.sm)

            // CALL-SCOPE-17 : kill-switch de repli — masque toute initiation
            // d'appel quand SQFeatures.callsEnabled est false.
            if SQFeatures.callsEnabled {
                Menu {
                    Button { startCall(mode: "audio") } label: {
                        Label("Appel audio", systemImage: "phone.fill")
                    }
                    Button { startCall(mode: "video") } label: {
                        Label("Appel vidéo", systemImage: "video.fill")
                    }
                } label: {
                    // CALL-OFFLINE-21 : grisé + désactivé hors-ligne (un appel
                    // lancé sans réseau échouerait et ferait flasher l'écran).
                    Image(systemName: "phone")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(networkPath.isOnline ? SQColor.label : SQColor.labelTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!networkPath.isOnline)
                .accessibilityLabel("Appeler")
            }

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
                Button { showSaved = true } label: {
                    Label("Messages enregistrés", systemImage: "bookmark")
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Plus d’options")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(SQColor.surfaceGlass)
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Avatar de l'autre participant (1:1) pour la barre haute.
    private var otherParticipantAvatarURL: URL? {
        guard !conversation.isGroup else { return nil }
        return conversation.participants.first { $0.userId != currentUserId }?.user.avatarUrl
            ?? conversation.participants.first?.user.avatarUrl
    }

    /// Présence : l'autre participant (1:1) est en ligne.
    private var otherIsOnline: Bool {
        guard !conversation.isGroup else { return false }
        return conversation.participants.contains { $0.userId != currentUserId && $0.presence?.isOnline == true }
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
                    clearComposer()
                }
            }
            if ephemeralEnabled {
                HStack(spacing: SQSpace.xs) {
                    Image(systemName: "timer").font(.system(size: 11)).accessibilityHidden(true)
                    Text("Messages éphémères · disparaissent après 24 h")
                        .font(SQType.micro)
                    Spacer(minLength: SQSpace.sm)
                    Button("Désactiver") { ephemeralEnabled = false }
                        .font(SQType.micro.weight(.semibold))
                        .buttonStyle(.plain)
                }
                .foregroundStyle(SQColor.brandRed)
                .padding(.horizontal)
                .padding(.top, SQSpace.sm)
                .transition(.opacity)
            }
            MessageComposerBar(
                canSend: canSend,
                isSending: isSending,
                isSharingLocation: isSharingLocation,
                isE2EE: isE2EE,
                seedText: composerSeed,
                seedToken: composerSeedToken,
                ephemeralEnabled: $ephemeralEnabled,
                onTyping: { newValue in
                    guard !newValue.isEmpty, canSend else { return }
                    signalTypingIfNeeded()
                },
                onSend: { text in Task { await send(text) } },
                onPoll: { showNewPoll = true },
                onSchedule: { text in
                    scheduleSeedText = text
                    showSchedulePicker = true
                },
                onShareLocation: { Task { await sendCurrentLocation() } },
                onPickPhoto: { item, caption in Task { await sendAttachment(item: item, caption: caption) } }
            )
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(SQColor.surfaceGlass)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func quoteBar(title: String, text: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SQColor.brandRed)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.brandRed)
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
            .accessibilityLabel("Fermer")
        }
        .padding(.horizontal)
        .padding(.top, SQSpace.sm)
    }

    // MARK: Bulles

    private func messageBubble(_ message: MessageItem) -> some View {
        let mine = (message.senderId == currentUserId)
        return HStack {
            if mine { Spacer(minLength: 72) }
            VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs) {
            VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs + 1) {
                if !mine, let name = message.sender?.displayName {
                    Text(name)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let quoted = quotedMessage(for: message) {
                    // Tap sur la citation → saut animé + surbrillance du message d'origine.
                    Button {
                        jumpToQuoted(quoted)
                    } label: {
                        HStack(spacing: SQSpace.xs + 2) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(mine ? SQColor.onAccent.opacity(0.6) : SQColor.brandRed)
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
                        .background((mine ? SQColor.onAccent.opacity(0.14) : SQColor.surfaceMuted.opacity(0.6)), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                attachmentsView(for: message, mine: mine)
                if message.deletedAt != nil {
                    Text("Message supprimé")
                        .font(SQType.caption.italic())
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary)
                } else if let shareCard = shareCard(for: message) {
                    // Partage envoyé par Android (publication / signal / speedtest / session…).
                    // La publication (`social_post`) est testée EN PREMIER car elle peut
                    // aussi porter une mesure : elle se rend en carte riche fidèle.
                    if shareCard.kind.lowercased() == "social_post" {
                        SharedPostCardBubble(card: shareCard, mine: mine)
                    } else if let signal = shareCard.signal {
                        SignalCardBubble(card: shareCard, signal: signal, mine: mine)
                    } else {
                        ShareCardBubble(card: shareCard, mine: mine)
                    }
                } else if let location = location(for: message) {
                    LocationBubble(location: location, mine: mine)
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
                            .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                    }
                    if let transcription = transcriptions[message.id], !transcription.isEmpty {
                        transcriptionView(transcription, mine: mine)
                    }
                }
                HStack(spacing: SQSpace.xs) {
                    if let created = message.createdAt {
                        Text(created, format: .dateTime.hour().minute())
                            .font(SQFont.body(10.5))
                            .foregroundStyle((mine ? SQColor.onAccent : SQColor.label).opacity(0.6))
                    }
                    if message.expiresAt != nil && message.deletedAt == nil {
                        Image(systemName: "timer")
                            .font(.system(size: 10))
                            .foregroundStyle((mine ? SQColor.onAccent : SQColor.label).opacity(0.6))
                            .accessibilityLabel("Message éphémère")
                    }
                    if message.editedAt != nil && message.deletedAt == nil {
                        Text("modifié")
                            .font(SQFont.body(10.5))
                            .foregroundStyle((mine ? SQColor.onAccent : SQColor.label).opacity(0.6))
                    }
                    if !message.reactions.isEmpty {
                        ForEach(reactionSummaries(for: message)) { reaction in
                            Text("\(reaction.emoji) \(reaction.count)")
                                .font(.caption2)
                                .padding(.horizontal, SQSpace.xs + 2).padding(.vertical, 3)
                                .background(mine ? SQColor.onAccent.opacity(0.18) : SQColor.surfaceMuted, in: Capsule())
                                .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                        }
                    }
                    sendStatusIndicator(for: message)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .background(mine ? SQColor.brandRed : SQColor.surface, in: bubbleShape(mine: mine))
            .sqShadowSoft()
            .accessibilityElement(children: .combine)
            .contextMenu { contextMenu(for: message, mine: mine) }
                threadReplyBadge(for: message)
            }
            if !mine { Spacer(minLength: 72) }
        }
    }

    /// Statut d'envoi optimiste sous la bulle (MSG-API-01). En cours : petite
    /// horloge discrète. Échec : « Échec · Réessayer » tappable qui rejoue
    /// l'envoi (même Idempotency-Key, donc sans doublon).
    @ViewBuilder
    private func sendStatusIndicator(for message: MessageItem) -> some View {
        switch sendStatus[message.id] {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(SQColor.onAccent.opacity(0.7))
                .accessibilityLabel("Envoi en cours")
        case .failed:
            Button {
                Haptics.medium()
                Task { await performSend(localId: message.id) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Échec · Réessayer")
                        .font(SQType.micro.weight(.semibold))
                }
                .foregroundStyle(SQColor.onAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Échec de l'envoi. Appuyer pour réessayer.")
        case .none:
            EmptyView()
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
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text("\(count) réponse\(count > 1 ? "s" : "")")
                        .font(SQType.micro)
                }
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, 4)
                .background(SQColor.surface, in: Capsule())
                .sqShadowSoft()
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
                .foregroundStyle(mine ? SQColor.onAccent.opacity(0.75) : SQColor.labelSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(SQType.caption.italic())
                .foregroundStyle(mine ? SQColor.onAccent.opacity(0.9) : SQColor.labelSecondary)
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
                let text = displayedContent(for: message)
                if isE2EE {
                    // MSG-PASTEBOARD-02 : texte déchiffré d'un message E2EE → copie
                    // bornée (pas de synchro Universal Clipboard, purge auto 1 min).
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: text]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
                    )
                } else {
                    UIPasteboard.general.string = text
                }
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
            Button {
                Task { await saveMessage(message) }
            } label: {
                Label("Enregistrer", systemImage: "bookmark")
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
                seedComposer(displayedContent(for: message))
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
                RemoteImage(url: attachment.url, maxDimension: 240, contentMode: .fill) {
                    Rectangle().fill(SQColor.surfaceMuted).sqShimmer()
                }
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            } else if let url = attachment.url {
                Link(destination: url) {
                    Label(attachment.fileName ?? "Pièce jointe", systemImage: "doc")
                        .font(SQType.caption)
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
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
                        .accessibilityHidden(true)
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
                        .font(.system(size: 11))
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityHidden(true)
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
                .padding(.horizontal, SQSpace.sm + 2)
                .padding(.vertical, SQSpace.xs + 2)
                .background(SQColor.surface, in: Capsule())
                .sqShadowSoft()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, SQSpace.xs)
                .transition(.opacity)
                .accessibilityLabel("En train d’écrire…")
        }
    }

    private func quotedMessage(for message: MessageItem) -> MessageItem? {
        guard let replyToId = message.replyToId else { return nil }
        return messages.first { $0.id == replyToId }
    }

    /// Saut vers le message cité : défilement animé + surbrillance transitoire.
    private func jumpToQuoted(_ message: MessageItem) {
        Haptics.selection()
        scrollTargetId = message.id
        highlightMessage(message.id)
    }

    private func highlightMessage(_ id: String) {
        withAnimation(SQMotion.fast) { highlightedMessageId = id }
        Task {
            try? await Task.sleep(nanoseconds: 850_000_000)
            await MainActor.run {
                if highlightedMessageId == id {
                    withAnimation(SQMotion.standard) { highlightedMessageId = nil }
                }
            }
        }
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

    /// Carte de partage (signal/speedtest/session/social) portée par le metadata —
    /// envoyée par Android. Le metadata des cartes est en clair même en E2EE. La
    /// garde `metadata != nil` évite tout parsing JSON sur les messages texte.
    private func shareCard(for message: MessageItem) -> ShareCardData? {
        guard message.deletedAt == nil, message.metadata != nil else { return nil }
        return ShareCardData.parse(fromMetadataJSON: message.metadata)
    }

    /// Localisation partagée (kind LOCATION) portée par le metadata.
    private func location(for message: MessageItem) -> MessageLocationData? {
        guard message.deletedAt == nil, message.metadata != nil else { return nil }
        return MessageLocationData.parse(fromMetadataJSON: message.metadata)
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
            let anchorId = messages.first?.id              // tête AVANT insertion
            messages.insert(contentsOf: older, at: 0)
            olderCursor = (page.hasMore ?? (page.nextCursor != nil)) ? page.nextCursor : nil
            prependAnchorId = anchorId                      // réancre le scroll (MSG-FLUIDITY-01)
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
                case .viewingEvent:
                    await refreshViewers()
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

    /// Présence « actif sur la conversation » (parité Android) : on signale au
    /// backend qu'on regarde la conv (ping 30 s) ; il diffuse l'event `viewing`
    /// aux autres participants. Coupé en arrière-plan / à la fermeture.
    private func startActivePing() {
        guard !AppEnvironment.usesDemoData else { return }
        activePingTask?.cancel()
        let conversationId = conversation.id
        activePingTask = Task {
            while !Task.isCancelled {
                await service.setConversationActive(conversationId: conversationId, active: true)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stopActivePing(sendLeave: Bool) {
        activePingTask?.cancel()
        activePingTask = nil
        if sendLeave {
            let conversationId = conversation.id
            Task { await service.setConversationActive(conversationId: conversationId, active: false) }
        }
    }

    private func refreshViewers() async {
        let viewers = await service.conversationViewers(conversationId: conversation.id)
        await MainActor.run {
            withAnimation(SQMotion.fast) { conversationViewers = viewers }
        }
    }

    /// Vrai quand l'autre participant (1:1) regarde actuellement la conversation.
    private var otherIsViewing: Bool {
        guard !conversation.isGroup, let uid = currentUserId else { return false }
        guard let otherId = conversation.participants.first(where: { $0.userId != uid })?.userId else { return false }
        return conversationViewers.contains(otherId)
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

    /// Vide le champ de saisie de la sous-vue composer (PERF-MSG-01) via le canal seed.
    private func clearComposer() {
        composerSeed = ""
        composerSeedToken &+= 1
    }

    /// Pré-remplit le champ de saisie de la sous-vue composer (édition d'un message).
    private func seedComposer(_ value: String) {
        composerSeed = value
        composerSeedToken &+= 1
    }

    private func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // L'édition n'est pas optimiste : on attend la confirmation serveur
        // avant de remplacer le texte affiché (recharge pour réordonner).
        if let editTarget {
            isSending = true
            defer { isSending = false }
            do {
                try await service.editMessage(messageId: editTarget.id, text: text, in: conversation, e2ee: e2ee)
                decryptedMessages[editTarget.id] = text
                self.editTarget = nil
                clearComposer()
                await load()
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
            return
        }

        // MSG-API-01 — Envoi optimiste : on insère une bulle locale (.sending)
        // IMMÉDIATEMENT et on vide le champ, sans attendre le réseau. L'appel
        // réel suit dans performSend, qui remplacera la bulle par la réponse
        // serveur ou la marquera .failed (rejouable au tap).
        let replyToId = replyTarget?.id
        let localId = "local-\(UUID().uuidString)"
        let ttl = ephemeralEnabled ? 86_400 : 0
        let optimistic = makeOptimisticMessage(id: localId, text: text, replyToId: replyToId, ttlSeconds: ttl)
        pendingSends[localId] = PendingSend(text: text, replyToId: replyToId, idempotencyKey: UUID().uuidString, ttlSeconds: ttl)
        sendStatus[localId] = .sending
        messages = Self.normalized(messages + [optimistic])
        clearComposer()
        replyTarget = nil
        Haptics.light()
        await performSend(localId: localId)
    }

    /// Réalise (ou rejoue) l'envoi d'une bulle optimiste. Réutilise la même
    /// Idempotency-Key à chaque tentative pour qu'un rejeu après échec réseau ne
    /// crée jamais de doublon côté serveur.
    private func performSend(localId: String) async {
        guard let pending = pendingSends[localId] else { return }
        sendStatus[localId] = .sending
        do {
            let sent = try await service.sendText(
                pending.text,
                in: conversation,
                replyToId: pending.replyToId,
                e2ee: e2ee,
                idempotencyKey: pending.idempotencyKey,
                ttlSeconds: pending.ttlSeconds
            )
            // Remplace la bulle optimiste par la réponse serveur (id réel,
            // horodatage serveur, état chiffré). On garde le texte déchiffré en
            // cache pour un affichage immédiat sans aller-retour de décryptage.
            var next = messages.filter { $0.id != localId }
            next.append(sent)
            messages = Self.normalized(next)
            if sent.isEncrypted {
                decryptedMessages[sent.id] = pending.text
            }
            sendStatus[localId] = nil
            pendingSends[localId] = nil
            Haptics.success()
        } catch {
            // On conserve la bulle et les données de rejeu : l'utilisateur peut
            // réessayer d'un tap. Pas de bannière d'erreur globale ici — le
            // feedback est porté par la bulle elle-même.
            withAnimation(SQMotion.fast) { sendStatus[localId] = .failed }
            Haptics.error()
        }
    }

    /// Construit une bulle locale en clair (jamais persistée) affichée le temps
    /// de l'aller-retour serveur. Non chiffrée : `displayedContent` lit
    /// directement `content`, ce qui évite tout décryptage pour la bulle locale.
    private func makeOptimisticMessage(id: String, text: String, replyToId: String?, ttlSeconds: Int = 0) -> MessageItem {
        MessageItem(
            id: id,
            conversationId: conversation.id,
            senderId: currentUserId,
            kind: "TEXT",
            content: text,
            e2eeVersion: nil,
            e2eeIvB64: nil,
            e2eeCiphertextB64: nil,
            e2eeAadB64: nil,
            metadata: nil,
            createdAt: Date(),
            editedAt: nil,
            deletedAt: nil,
            expiresAt: ttlSeconds > 0 ? Date().addingTimeInterval(TimeInterval(ttlSeconds)) : nil,
            replyToId: replyToId,
            threadReplyCount: nil,
            sender: nil,
            attachments: [],
            reactions: []
        )
    }

    private func sendAttachment(item: PhotosPickerItem, caption rawCaption: String) async {
        isSending = true
        defer { isSending = false }
        do {
            guard !isE2EE else {
                throw E2EEError.unsupported("Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils.")
            }
            guard let raw = try await item.loadTransferable(type: Data.self) else { return }
            // Décodage/redimensionnement/encodage hors du main thread pour ne pas
            // geler l'UI pendant l'envoi (image plein format).
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                Self.preparedJPEG(from: raw)
            }).value else {
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
            let caption = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
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
            clearComposer()
            replyTarget = nil
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Recompresse l'image en JPEG ≤ 1280 px qualité 0,85 (HEIC converti
    /// d'office) — même normalisation qu'Android avant upload.
    nonisolated private static func preparedJPEG(from data: Data) -> (data: Data, width: Int, height: Int)? {
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

    // MARK: Partage de position (parité Android)

    private func sendCurrentLocation() async {
        guard !isSharingLocation else { return }
        isSharingLocation = true
        defer { isSharingLocation = false }
        guard let location = await services.location.currentLocation() else {
            errorMessage = "Position indisponible — autorise la localisation dans les réglages."
            Haptics.error()
            return
        }
        let place = await reverseGeocodedName(location)
        do {
            let sent = try await service.sendLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                place: place,
                in: conversation
            )
            messages = Self.normalized(messages + [sent])
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Géocodage inverse best-effort (« rue, ville ») pour libeller la position ;
    /// nil si indisponible — la carte affichera alors les coordonnées.
    private func reverseGeocodedName(_ location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let placemark = placemarks?.first
                let parts = [placemark?.thoroughfare, placemark?.locality].compactMap { $0 }
                continuation.resume(returning: parts.isEmpty ? placemark?.name : parts.joined(separator: ", "))
            }
        }
    }

    // MARK: Messages enregistrés (favoris)

    private func saveMessage(_ message: MessageItem) async {
        do {
            try await service.saveMessage(messageId: message.id)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
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
        guard conversation.participants.count >= 2 else {
            errorMessage = "Aucun autre participant n’est disponible pour cet appel."
            Haptics.error()
            return
        }
        guard CallLifecyclePolicy.canStartCall(participantCount: conversation.participants.count) else {
            errorMessage = "Les appels de groupe sont limités à 8 participants."
            Haptics.error()
            return
        }
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
        let pending = messages.filter { $0.isEncrypted && decryptedMessages[$0.id] == nil }
        guard !pending.isEmpty else { return }

        // MSG-PERF-01 — Le 1er message est déchiffré séquentiellement : il résout
        // (et met en cache) la clé de conversation, ce qui évite N fetchs réseau
        // concurrents. Cela permet aussi de détecter une rotation de clé (staleKey)
        // une seule fois avant de paralléliser le reste.
        var results: [String: String] = [:]
        let conversationId = conversation.id
        do {
            results[pending[0].id] = try await e2ee.decryptText(conversationId: conversationId, message: pending[0])
        } catch let error as E2EEError where error == .staleKey {
            // E2EE-UX-04 : clé tournée côté autre plateforme → bandeau de resync
            // au lieu de bulles muettes définitives.
            withAnimation(SQMotion.fast) { needsKeyResync = true }
            return
        } catch {
            MessageSyncLog.logger.error("decrypt \(pending[0].id, privacy: .public) erreur: \(error.localizedDescription, privacy: .private)")
        }

        // Le reste est déchiffré en parallèle (clé déjà en cache), puis appliqué
        // en UNE seule mutation pour ne provoquer qu'un re-render.
        let rest = Array(pending.dropFirst())
        if !rest.isEmpty {
            await withTaskGroup(of: (String, String?).self) { group in
                for message in rest {
                    group.addTask {
                        let text = try? await e2ee.decryptText(conversationId: conversationId, message: message)
                        return (message.id, text)
                    }
                }
                for await (id, text) in group {
                    if let text { results[id] = text }
                }
            }
        }
        guard !results.isEmpty else { return }
        needsKeyResync = false
        decryptedMessages.merge(results) { _, new in new }
    }

    /// E2EE-UX-04 — Resynchronise la clé de conversation après une rotation :
    /// re-partage best-effort (si on détient encore la clé) puis re-tente le
    /// décryptage. Le bandeau reste tant que les messages restent illisibles.
    private func resyncKey() async {
        guard let e2ee, !isResyncingKey else { return }
        isResyncingKey = true
        defer { isResyncingKey = false }
        await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
        await refreshE2EEState()
        await decryptLoadedMessages()
        await decryptPinnedIfNeeded()
        if !needsKeyResync { Haptics.success() }
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

/// Barre de saisie isolée (PERF-MSG-01) : possède son propre `@State text` afin que la
/// frappe n'invalide PAS le corps de `ConversationDetailView` (et donc la liste des
/// messages) à chaque caractère. Le parent POUSSE du texte (pré-remplissage édition,
/// vidage après envoi) via `seedText`/`seedToken` (appliqué au seul changement de
/// token) ; il REÇOIT le texte courant via les closures d'action.
private struct MessageComposerBar: View {
    let canSend: Bool
    let isSending: Bool
    let isSharingLocation: Bool
    let isE2EE: Bool
    let seedText: String
    let seedToken: Int
    @Binding var ephemeralEnabled: Bool
    let onTyping: (String) -> Void
    let onSend: (String) -> Void
    let onPoll: () -> Void
    let onSchedule: (String) -> Void
    let onShareLocation: () -> Void
    let onPickPhoto: (PhotosPickerItem, String) -> Void

    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        HStack(spacing: SQSpace.sm + 2) {
            Menu {
                Button { onPoll() } label: {
                    Label("Créer un sondage", systemImage: "chart.bar")
                }
                Button { onSchedule(text) } label: {
                    Label("Programmer l'envoi", systemImage: "clock")
                }
                // Localisation : refusée par le backend en E2EE → proposée
                // uniquement en conversation non chiffrée.
                if !isE2EE {
                    Button { onShareLocation() } label: {
                        Label("Partager ma position", systemImage: "location.fill")
                    }
                }
                Divider()
                Toggle(isOn: $ephemeralEnabled) {
                    Label("Messages éphémères (24 h)", systemImage: "timer")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(SQColor.surfaceMuted, in: Circle())
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(!canSend || isSending || isSharingLocation)
            .accessibilityLabel("Plus d'actions")

            if !isE2EE {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(SQColor.surfaceMuted, in: Circle())
                        .foregroundStyle(SQColor.label)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(!canSend || isSending)
                .accessibilityLabel("Joindre une photo")
            }

            TextField(canSend ? "Message…" : "Chiffrement à déverrouiller", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.lg + 2)
                .padding(.vertical, SQSpace.sm)
                .frame(minHeight: 44)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .disabled(!canSend)

            Button {
                onSend(text)
            } label: {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(SQColor.brandRed, in: Circle())
                    .foregroundStyle(SQColor.onAccent)
                    .sqShadowAccent()
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || !canSend)
            .accessibilityLabel(isSending ? "Envoi en cours" : "Envoyer le message")
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.sm + 2)
        .onChangeCompat(of: text) { _, newValue in onTyping(newValue) }
        .onChangeCompat(of: seedToken) { _, _ in text = seedText }
        .onChangeCompat(of: pickerItem) { _, item in
            guard let item else { return }
            onPickPhoto(item, text)
            pickerItem = nil
        }
    }
}

private struct MessageReactionSummary: Identifiable {
    let emoji: String
    let count: Int

    var id: String { emoji }
}

/// Statut d'une bulle envoyée de façon optimiste (MSG-API-01).
private enum MessageSendStatus: Equatable { case sending, failed }

/// Tout ce qu'il faut pour rejouer un envoi échoué à l'identique (sans
/// régénérer l'Idempotency-Key, donc sans risque de doublon serveur).
private struct PendingSend {
    let text: String
    let replyToId: String?
    let idempotencyKey: String
    let ttlSeconds: Int
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
