import SwiftUI

@MainActor
final class MessagesViewModel: ObservableObject {
    @Published var conversations: [MessageConversation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Aperçus déchiffrés du dernier message, par id de conversation.
    @Published var decryptedPreviews: [String: String] = [:]
    /// Limite d'épinglage du compte (P2-46), quand le serveur la sert.
    @Published var pinLimit: Int?

    /// « Épingler » ne se propose plus une fois la limite atteinte.
    var canPinMore: Bool {
        guard let pinLimit else { return true }
        return conversations.filter { $0.pinnedAt != nil }.count < pinLimit
    }

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
            let list = try await service.conversationList()
            conversations = list.conversations.inDisplayOrder()
            pinLimit = list.pinLimit
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Déchiffre les aperçus des derniers messages des conversations E2EE une
    /// fois la clé déverrouillée. Best-effort : un échec laisse le cadenas.
    func decryptPreviews(e2ee: E2EEServicing?, v2: E2EEV2MessagingRuntime? = nil) async {
        // v2 : le dernier message vérifié et gardé ici, sans requête ni clé v1.
        if let v2 {
            for conversation in conversations where EncryptedConversationSurfaces.isV2(conversation) {
                if let text = v2.latestText(conversationId: conversation.id) { decryptedPreviews[conversation.id] = text }
            }
        }
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
            if case APIError.http(_, "CONVERSATION_PIN_LIMIT", _, _, _) = error {
                errorMessage = String(localized: "Tu as déjà épinglé le nombre maximal de conversations. Désépingles-en une pour en épingler une autre.")
            } else if !error.isCancellation {
                errorMessage = error.userFacingMessage
            }
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
    func leave(_ conversation: MessageConversation, v2: E2EEV2MessagingRuntime? = nil) async {
        do {
            // Conversation v2 : le départ passe par la chaîne signée (D.4).
            if let v2, v2.writesEnabled, EncryptedConversationSurfaces.isV2(conversation) {
                try await v2.apply(.leave, to: conversation)
            } else {
                try await service.leaveConversation(id: conversation.id)
            }
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
    /// Porte E2EE v2 ouverte côté serveur, mais cet appareil n'y est pas encore entré.
    @State private var needsV2Activation = false
    @State private var showV2Activation = false

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

    private func refreshV2Activation() {
        guard services.e2eeV2Messaging.writesEnabled, let current = LocalAccountScope.sessionSnapshot() else {
            needsV2Activation = false
            return
        }
        let snoozedUntil = UserDefaults.standard.double(forKey: Self.activationSnoozeKey(current))
        needsV2Activation = services.e2eeV2Messaging.lacksV2Readiness(current)
            && Date().timeIntervalSince1970 >= snoozedUntil
    }

    /// « Plus tard » : la carte revient au bout d'une semaine ; l'activation
    /// reste à portée dans Réglages › Appareils.
    private func snoozeV2Activation() {
        guard let current = LocalAccountScope.sessionSnapshot() else { return }
        UserDefaults.standard.set(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970,
                                  forKey: Self.activationSnoozeKey(current))
        needsV2Activation = false
    }

    private static func activationSnoozeKey(_ session: LocalAccountSession) -> String {
        "sq.e2ee.v2.activation-snoozed.\(session.ownerNamespace)"
    }

    /// Activation guidée : l'enregistrement de l'appareil et l'approbation
    /// demandent un geste (code e-mail du premier appareil, ou un appareil déjà
    /// approuvé), jamais faits en silence.
    private var v2ActivationCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label("Messages et appels chiffrés", systemImage: "lock.shield")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Text("Active le chiffrement de bout en bout sur cet appareil pour écrire et appeler en privé.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Activer sur cet appareil"), style: .primary, allowsMultiline: true) {
                showV2Activation = true
            }
            .accessibilityIdentifier("e2ee-v2-activation-open")
            GradientButton(String(localized: "Plus tard"), style: .ghost, allowsMultiline: true) {
                snoozeV2Activation()
            }
            .accessibilityIdentifier("e2ee-v2-activation-later")
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                if needsV2Activation {
                    v2ActivationCard
                }
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
        // §13 : un aperçu déchiffré ou un brouillon chiffré n'apparaît jamais
        // dans le sélecteur d'apps.
        .background {
            if EncryptedConversationSurfaces.listHidesSnapshot(
                model.conversations, decryptedPreviews: model.decryptedPreviews, drafts: drafts
            ) {
                AppSensitiveContentMarker()
            }
        }
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
            await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
            await openRoutedConversationIfNeeded()
        }
        // Message v2 reçu app ouverte : la liste (non-lus, ordre) se met à jour.
        .onReceive(NotificationCenter.default.publisher(for: PushNotificationService.e2eeV2EnvelopeReceived)) { _ in
            Task {
                await model.load()
                await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
            }
        }
        // Au retour d'une conversation : la liste restait figée jusqu'au
        // tirer-pour-rafraîchir (SOC-23). Le premier affichage passe par `.task`.
        .onAppear {
            guard !model.conversations.isEmpty else { return }
            Task {
                await model.load()
                await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
                await services.refreshInboxBadge(force: true)
            }
        }
        .refreshable {
            await model.load()
            await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
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
                Task { await model.leave(conversation, v2: services.e2eeV2Messaging); await services.refreshInboxBadge(force: true) }
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
        .task(id: PushOwnerScope.current) { refreshV2Activation() }
        .onAppear { refreshV2Activation() }
        .onReceive(NotificationCenter.default.publisher(for: E2EEV2ServerGate.didChange).receive(on: RunLoop.main)) { _ in
            refreshV2Activation()
        }
        .sheet(isPresented: $showV2Activation, onDismiss: refreshV2Activation) {
            NavigationStack {
                E2EEV2TrustedDevicesView(api: services.api)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { showV2Activation = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationSheet(
                service: service,
                onCreated: { await model.refreshAfterCreate() },
                existingDirect: { peerId in
                    model.conversations.first { conversation in
                        !conversation.isGroup && (conversation.directPeerUserId == peerId
                            || conversation.participants.contains { $0.userId == peerId })
                    }?.id
                },
                onOpenExisting: { id in
                    Task {
                        if !model.conversations.contains(where: { $0.id == id }) { await model.load() }
                        routedConversationId = id
                    }
                }
            )
        }
        .sheet(isPresented: $showE2EEUnlock, onDismiss: openNewConversationIfRequested) {
            if let e2ee = e2ee, case .authenticated(let user) = session.state {
                E2EEUnlockSheet(userId: user.id, service: e2ee) {
                    Task {
                        await model.load()
                        await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
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
        // Message v2 : le serveur n'en sert qu'un aperçu vide (lot A7).
        if conversation.e2eeV2?.lastMessage != nil { return String(localized: "Message chiffré") }
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
                    Text(title.isEmpty ? String(localized: "Conversation") : title)
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

    @ViewBuilder
    private func pinButton(_ conversation: MessageConversation) -> some View {
        let pinned = conversation.pinnedAt != nil
        // Limite d'épinglage atteinte (P2-46) : seul « Désépingler » reste.
        if pinned || model.canPinMore {
            Button {
                Haptics.light()
                Task { await model.setPinned(!pinned, conversation) }
            } label: {
                Label(pinned ? "Désépingler" : "Épingler", systemImage: pinned ? "pin.slash" : "pin")
            }
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
    /// Un tête-à-tête avec cette personne existe déjà : on l'ouvre au lieu
    /// d'en créer un second (v1 comme v2).
    var existingDirect: (String) -> String? = { _ in nil }
    var onOpenExisting: (String) -> Void = { _ in }

    @EnvironmentObject private var services: AppServices
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
            let isGroup = selected.count > 1
            if !isGroup, let peer = selected.first, let existing = existingDirect(peer.id) {
                dismiss()
                onOpenExisting(existing)
                return
            }
            // Chiffrée et verrous ouverts : naît en v2 si tous les membres le
            // lisent ; sinon en v1, tant que le serveur l'accepte (v0.4.17).
            // Un appareil pas encore activé en v2 crée en v1 ; une porte serveur
            // refermée aussi, rien n'ayant été créé.
            if e2ee, services.e2eeV2Messaging.writesEnabled,
               let session = LocalAccountScope.sessionSnapshot(),
               !services.e2eeV2Messaging.lacksV2Readiness(session) {
                switch await services.e2eeV2Messaging.create(
                    participantIds: selected.map(\.id), isGroup: isGroup,
                    title: isGroup && !normalizedTitle.isEmpty ? normalizedTitle : nil, excludesWeb: false
                ) {
                case .created:
                    Haptics.success()
                    await onCreated()
                    dismiss()
                    return
                case .failure(let failure) where failure.message == "e2ee-v2-capability-missing"
                    || failure.kind == .activationBlocked:
                    break
                // Créé entre-temps ailleurs (autre appareil, autre plateforme) : on l'ouvre.
                case .failure(let failure) where failure.code == "E2EE_DIRECT_CONVERSATION_EXISTS":
                    if case .string(let existing)? = failure.details?["conversationId"] {
                        await onCreated()
                        dismiss()
                        onOpenExisting(existing)
                        return
                    }
                    throw E2EEV2MessagingError(String(localized: "La conversation chiffrée n’a pas pu être créée."))
                case .failure(let failure):
                    throw E2EEV2MessagingError(failure.kind == .retryable
                        ? String(localized: "Connexion instable. Réessaie.")
                        : String(localized: "La conversation chiffrée n’a pas pu être créée."))
                }
            }
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
            ),
            // Groupe non chiffré : les mentions n'existent que là.
            MessageConversation(
                id: "demo-conv-3",
                title: "Équipe terrain",
                isGroup: true,
                e2eeEnabled: false,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastMessageAt: Date().addingTimeInterval(-7_200),
                lastReadAt: Date(),
                pinnedAt: nil,
                participants: [
                    ConversationParticipant(
                        userId: "mock-user", role: "owner", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "mock-user", name: "SignalQuest iOS", email: "ios@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user", role: "member", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user-2", role: "member", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "demo-user-2", name: "Léa", email: "lea@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    )
                ],
                lastMessage: MessageItem(
                    id: "demo-group-message-1", conversationId: "demo-conv-3", senderId: "demo-user-2", kind: "TEXT",
                    content: "On se retrouve au pylône nord samedi ? https://signalquest.fr/carte", e2eeVersion: nil, e2eeIvB64: nil,
                    e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                    createdAt: Date().addingTimeInterval(-7_200), editedAt: nil, deletedAt: nil, replyToId: nil,
                    threadReplyCount: 0,
                    sender: MessageUser(id: "demo-user-2", name: "Léa", email: "lea@signalquest.fr", avatarUrl: nil),
                    attachments: [], reactions: []
                )
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
