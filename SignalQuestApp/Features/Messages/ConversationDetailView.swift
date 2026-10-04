import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import CoreLocation
import MapKit

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// Brouillon de la conversation, chiffré sur l'appareil (plan 3, vague 1).
    @State private var draftAutosaver: MessageDraftAutosaver?
    @State private var replyTarget: MessageItem?
    @State private var editTarget: MessageItem?
    @State private var errorMessage: String?
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @State private var isSending = false
    @State private var showUnlockSheet = false
    /// Appel demandé dans une conversation chiffrée alors que la v2 n'est pas
    /// prête : on attend la confirmation « Appeler quand même » (mode audio/vidéo).
    @State private var pendingTransportOnlyCall: String?
    @State private var syncTask: Task<Void, Never>?
    /// Vrai entre l'apparition et la disparition de l'écran : ni la synchro ni la
    /// présence ne démarrent pour une conversation qui n'est plus affichée (SOC-03).
    @State private var isOnScreen = false
    @State private var isE2EEUnlocked = false
    /// Conversation v2 (§12), lue une fois à l'ouverture : messages programmés
    /// désactivés (§13).
    @State private var conversationIsV2 = false
    /// Avis du fil v2 (§2.4, §4.2, §4.3, §3.2), posés en tête.
    @State private var v2Notices: [E2EEV2ThreadPresentation.Notice] = []
    /// Membre dont le numéro de sécurité est ouvert depuis un avis du fil (§2.4).
    @State private var safetyNumberPeer: SafetyNumberPeer?
    @State private var showEncryptionInfo = false
    /// Suivi du bas de la conversation : un message qui arrive pendant la
    /// lecture de l'historique n'y ramène plus de force (SOC-20).
    @State private var isNearBottom = true
    @State private var hasUnseenMessages = false
    /// Actions destructives confirmées avant exécution (SOC-22).
    @State private var pendingDeletion: PendingMessageDeletion?
    @State private var reportTarget: MessageItem?
    @State private var confirmBlockOther = false
    @State private var pendingBlockSenderId: String?
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
    /// Posé par les réglages après un départ du groupe : la conversation se ferme.
    @State private var leftGroup = false
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
    /// Médias et fichiers de la conversation (plan 3, vague 2).
    @State private var showMedia = false
    /// Messages éphémères (parité Android) : quand actif, les textes envoyés
    /// portent un TTL de 24 h (le backend pose `expiresAt`).
    @State private var ephemeralEnabled = false
    @State private var isSharingLocation = false
    @State private var showLiveShare = false
    @State private var showSchedulePicker = false
    @State private var showNewPoll = false
    @State private var reminderTarget: MessageItem?

    // Photos en grand + publications partagées interactives (parité Android).
    /// Photo de la conversation ouverte en plein écran (tap sur l'image).
    @State private var imageViewerTarget: MessageImageTarget?
    /// Cache mémoire des publications partagées (1 fetch par postId) + actions
    /// like/repost optimistes, partagé par toutes les bulles de la conversation.
    @StateObject private var sharedPosts = SharedPostStore()
    /// Sheet commentaires d'une publication partagée.
    @State private var sharedPostComments: SharedPostCommentsTarget?
    /// Sheet « publication complète » (PostDetailView) d'une publication partagée.
    @State private var sharedPostDetail: SharedPostDetailTarget?
    /// Clé de cache du dernier post ouvert en sheet — rafraîchi au retour pour
    /// garder les compteurs de l'embed à jour.
    @State private var lastSharedPostKey: String?

    /// PERF-MSG-03 / PERF-MSG-04 — Cache de rendu mémoïsé (type référence, cf.
    /// `MessageRenderCache`) partagé par toutes les bulles et conservé entre les
    /// réévaluations du `body` : parsing des cartes de partage / positions +
    /// index O(1) d'un message dans la liste. Muter son contenu pendant le rendu
    /// ne réassigne pas le `@State` (référence inchangée) → ni warning « state
    /// during view update » ni re-render.
    @State private var renderCache = MessageRenderCache()

    private var isE2EE: Bool { conversation.e2eeEnabled == true }
    private var canSend: Bool { !isE2EE || isE2EEUnlocked }
    /// Les médias d'une conversation sont privés même si leur URL ressemble à
    /// une URL CDN ordinaire. La session est capturée avant chaque rendu afin
    /// qu'un résultat tardif ne traverse jamais un changement de compte.
    private var privateImageCacheScope: ImageCacheScope? {
        guard case .authenticated(let user) = session.state,
              let localSession = LocalAccountScope.sessionSnapshot(),
              localSession.ownerScopeId == "user:\(user.id)" else { return nil }
        return .privateAccount(localSession)
    }
    /// Suggestions de mention, seulement dans un groupe non chiffré.
    private var mentionSuggestionProvider: ((String) async -> [MentionCandidate])? {
        guard conversation.isGroup, !isE2EE else { return nil }
        return { prefix in await mentionCandidates(for: prefix) }
    }

    /// Amis membres du groupe dont le nom ou le pseudo commence par `prefix`
    /// (plan 3, vague 2) : le serveur ne notifie une mention qu'à eux, et ne
    /// lit pas le texte d'une conversation chiffrée.
    private func mentionCandidates(for prefix: String) async -> [MentionCandidate] {
        let members = Set(conversation.participants.map(\.userId)).subtracting([currentUserId].compactMap { $0 })
        let found = (try? await service.mentionSuggestions(prefix: prefix)) ?? []
        return found.filter { members.contains($0.id) }
    }

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
                    // Espacement géré par message (groupes 2/10 pt + horodatages
                    // de section) — le spacing uniforme est donc à 0.
                    LazyVStack(spacing: 0) {
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
                        ForEach(Array(v2Notices.enumerated()), id: \.offset) { _, notice in
                            if case .identityChanged(let userId, let name) = notice {
                                // L'envoi attend ce membre : l'avis mène à son numéro.
                                Button {
                                    safetyNumberPeer = SafetyNumberPeer(userId: userId, name: name)
                                } label: {
                                    v2NoticeLabel(notice, detail: String(localized: "Voir le numéro de sécurité"))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("conversation.v2Notice.safetyNumber")
                            } else {
                                v2NoticeLabel(notice, detail: nil)
                                    .accessibilityIdentifier("conversation.v2Notice")
                            }
                        }
                        // PERF-MSG-04 — Itère directement sur `messages` (identité
                        // stable `\.id`, comme l'ancien `id: \.element.id`) au lieu
                        // de `Array(messages.enumerated())`, qui matérialisait un
                        // tableau de tuples à CHAQUE évaluation du body (frappe,
                        // sendStatus, surbrillance…). L'index — nécessaire à l'accès
                        // aux voisins — vient d'une table O(1) mémoïsée, reconstruite
                        // seulement quand la structure de la liste change.
                        ForEach(messages) { message in
                            let index = renderCache.index(of: message, in: messages)
                            let previous = index > 0 ? messages[index - 1] : nil
                            let next = index + 1 < messages.count ? messages[index + 1] : nil
                            let stamp = sectionStamp(for: message, previous: previous)
                            VStack(spacing: 0) {
                                if let stamp {
                                    Text(stamp)
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, SQSpace.sm)
                                        .accessibilityIdentifier("conversation.stamp")
                                }
                                messageBubble(
                                    message,
                                    isGroupStart: stamp != nil || previous == nil || previous?.senderId != message.senderId,
                                    isGroupEnd: isGroupEnd(message, next: next)
                                )
                            }
                            // Groupes de messages : même auteur = 2 pt, changement
                            // d'auteur = 10 pt (l'horodatage de section gère le sien).
                            .padding(.top, stamp != nil ? SQSpace.xs : (previous == nil ? 0 : (previous?.senderId == message.senderId ? 2 : 10)))
                            .id(message.id)
                            .background(
                                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                    .fill(SQColor.brandRed.opacity(highlightedMessageId == message.id ? 0.14 : 0))
                            )
                            .sqAnimation(SQMotion.standard, value: highlightedMessageId)
                        }
                        readReceiptFooter
                        Color.clear
                            .frame(height: 1)
                            .onAppear { isNearBottom = true; hasUnseenMessages = false }
                            .onDisappear { isNearBottom = false }
                        if let errorMessage {
                            ErrorStateView(title: "Messages indisponibles", message: errorMessage) {
                                Task { usesV2 ? await loadV2() : await load() }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding()
                    // iPad : bulles dans une colonne lisible (SOC-27).
                    .sqReadableWidth()
                }
                // On suit le DERNIER id (pas le count) : prepender d'anciens messages
                // ne doit pas refaire défiler vers le bas.
                .onChangeCompat(of: messages.last?.id) { _, _ in
                    guard let last = messages.last else { return }
                    let mine = last.id.hasPrefix("local-") || last.senderId == currentUserId
                    if isNearBottom || mine {
                        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    } else {
                        hasUnseenMessages = true
                    }
                }
                .overlay(alignment: .bottom) {
                    if hasUnseenMessages {
                        Button {
                            Haptics.selection()
                            hasUnseenMessages = false
                            if let last = messages.last { withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                        } label: {
                            Label("Nouveaux messages", systemImage: "arrow.down")
                                .font(SQFont.body(13, .semibold))
                                .foregroundStyle(SQColor.onAccent)
                                .padding(.horizontal, SQSpace.md)
                                .padding(.vertical, SQSpace.sm)
                                .background(SQColor.brandRed, in: Capsule(style: .continuous))
                                .sqShadowSoft()
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, SQSpace.sm)
                        .transition(.opacity)
                        .accessibilityIdentifier("conversation.newMessages")
                    }
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
                    withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(target, anchor: .center) }
                    scrollTargetId = nil
                }
            }

            // Frappe : ligne compacte épinglée juste au-dessus du composer (parité
            // Android — auparavant dans l'en-tête, désormais en bas de conversation).
            typingIndicator
                .padding(.horizontal)
                .sqReadableWidth()
            if !isE2EE, let currentUserId {
                LiveShareConversationBar(
                    coordinator: services.liveShare,
                    conversation: conversation,
                    currentUserId: currentUserId,
                    onManage: { showLiveShare = true }
                )
                .padding(.horizontal)
                .padding(.bottom, SQSpace.xs)
                .sqReadableWidth()
            }
            if v2Unavailable {
                // §12 : une conversation v2 ne repasse jamais par la clé v1.
                Label(String(localized: "Cette conversation chiffrée n’est pas disponible dans cette version de SignalQuest."),
                      systemImage: "lock.trianglebadge.exclamationmark")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, SQSpace.sm)
                    .accessibilityIdentifier("conversation.v2Unavailable")
                    .sqReadableWidth()
            } else {
                composer
                    .sqReadableWidth()
            }
        }
        // Barre masquée pour l'en-tête maison ; le balayage retour, que UIKit
        // coupe avec la barre, est rétabli (SOC-30).
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .onAppear { OpenConversationTracker.opened(conversation.id) }
        .onDisappear { OpenConversationTracker.closed(conversation.id) }
        .navigationDestination(isPresented: $showSearch) {
            MessageSearchView(
                conversation: conversation, service: service, e2ee: e2ee,
                localCorpus: isE2EE
                    ? messages.compactMap { message in decryptedMessages[message.id].map { (message: message, text: $0) } }
                    : nil
            ) { messageId in
                handleSearchSelection(messageId)
            }
        }
        .navigationDestination(isPresented: $showMedia) {
            ConversationMediaView(conversation: conversation, service: service)
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
        // SOC-22 : supprimer ou bloquer ne partent plus d'un seul toucher.
        .confirmationDialog(
            pendingDeletion?.forEveryone == true ? "Supprimer ce message pour tout le monde ?" : "Supprimer ce message pour toi ?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { pending in
            Button(pending.forEveryone ? "Supprimer pour tous" : "Supprimer pour moi", role: .destructive) {
                Task { await delete(message: pending.message, forEveryone: pending.forEveryone) }
            }
        } message: { pending in
            Text(pending.forEveryone
                 ? "Le message disparaîtra aussi chez les autres membres."
                 : "Le message disparaîtra de ton côté seulement.")
        }
        .confirmationDialog("Bloquer \(conversationTitle) ?", isPresented: $confirmBlockOther, titleVisibility: .visible) {
            Button("Bloquer", role: .destructive) { Task { await blockOther() } }
        } message: {
            Text("Tu ne recevras plus ses messages.")
        }
        .confirmationDialog(
            "Bloquer cet expéditeur ?",
            isPresented: Binding(get: { pendingBlockSenderId != nil }, set: { if !$0 { pendingBlockSenderId = nil } }),
            titleVisibility: .visible,
            presenting: pendingBlockSenderId
        ) { senderId in
            Button("Bloquer", role: .destructive) { Task { await blockSender(userId: senderId) } }
        } message: { _ in
            Text("Tu ne recevras plus ses messages, dans ce groupe comme ailleurs.")
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
        .sheet(isPresented: $showLiveShare) {
            if let currentUserId {
                LiveShareManagementSheet(
                    coordinator: services.liveShare,
                    conversation: conversation,
                    currentUserId: currentUserId
                )
            }
        }
        .sheet(item: $reminderTarget) { target in
            AddReminderSheet(conversation: conversation, message: target, service: service) {
                Haptics.success()
            }
        }
        .sheet(isPresented: $showReportUser) {
            if let id = otherParticipantId {
                ReportSheet(target: .profile(id), service: services.reports)
            }
        }
        .sheet(item: $safetyNumberPeer, onDismiss: { Task { await loadV2() } }) { peer in
            if let access = services.e2eeV2Messaging.safetyNumberAccess() {
                NavigationStack {
                    E2EEV2SafetyNumberView(
                        peerUserId: peer.userId,
                        peerName: peer.name ?? String(localized: "Ce membre"),
                        ownUserId: access.ownUserId,
                        ownAccountKey: access.ownAccountKey,
                        trust: access.trust
                    )
                }
            }
        }
        .sheet(item: $reportTarget) { message in
            ReportSheet(
                reasons: ReportReason.messageReasons,
                notice: isE2EE
                    ? String(localized: "Conversation chiffrée : si l’équipe de modération dispose d’une clé de vérification, la clé de cette conversation lui est transmise, chiffrée pour elle seule. Elle pourra alors en lire les messages.")
                    : nil
            ) { reason, comment in
                try await report(message, reason: reason, comment: comment)
            }
        }
        .sheet(isPresented: $showGroupSettings, onDismiss: { if leftGroup { dismiss() } }) {
            GroupSettingsView(conversation: conversation, service: service, e2ee: e2ee) {
                // Groupe quitté : rester sur la conversation n'aurait plus de sens.
                leftGroup = true
            }
        }
        .sheet(isPresented: $showSaved) {
            SavedMessagesView(service: service, currentUserId: currentUserId, e2ee: e2ee)
        }
        // Photo de la conversation en plein écran (zoom + glisser pour fermer).
        .fullScreenCover(item: $imageViewerTarget) { target in
            MessageImageViewer(target: target)
        }
        // Commentaires d'une publication partagée — même sheet que le feed ;
        // au retour, l'embed est rafraîchi (compteur de commentaires).
        .sheet(item: $sharedPostComments, onDismiss: { refreshSharedPostAfterSheet() }) { target in
            CommentsSheet(service: services.comments, postId: target.backendPostId,
                          profileService: services.feed, reports: services.reports)
        }
        // Publication complète (réutilise PostDetailView du feed par composition).
        .sheet(item: $sharedPostDetail, onDismiss: { refreshSharedPostAfterSheet() }) { target in
            NavigationStack {
                PostDetailView(
                    item: target.item,
                    feedService: services.feed,
                    messagesService: services.messages,
                    commentsService: services.comments,
                    reportsService: services.reports,
                    onItemChanged: { sharedPosts.acceptDetailItem($0, for: target.id) }
                )
            }
        }
        .signalQuestBackground()
        // §13 : l'aperçu du sélecteur d'apps ne montre jamais une conversation
        // chiffrée, même sans verrouillage de l'app.
        .background {
            if EncryptedConversationSurfaces.hidesSnapshot(of: conversation) { AppSensitiveContentMarker() }
        }
        .onAppear {
            // Le dock flottant global est masqué le temps de la conversation.
            router.isDockHidden = true
            isOnScreen = true
        }
        .task {
            conversationIsV2 = EncryptedConversationSurfaces.isV2(conversation)
            // §14.2 : une conversation chiffrée v1 passe en v2 à son ouverture,
            // si tous ses membres lisent le v2 (règle commune, v0.4.17).
            if !conversationIsV2, conversation.e2eeEnabled == true,
               await services.e2eeV2Messaging.migrateIfReady(conversation) {
                conversationIsV2 = true
            }
            await restoreDraftIfNeeded()
            if usesV2 {
                await loadV2()
                guard !Task.isCancelled else { return }
                await markRead()
                return
            }
            // SwiftUI annule cette tâche quand on quitte l'écran, mais les appels
            // en cours finissent quand même : sans ces gardes, une sortie rapide
            // démarrait ensuite la synchro et la présence que plus rien n'arrêtait
            // (flux, relevé toutes les 12 s, ping toutes les 30 s) et envoyait un
            // faux « Vu » à l'autre personne (SOC-03).
            await load()
            guard !Task.isCancelled else { return }
            await markRead()
            guard !Task.isCancelled else { return }
            await shareKeyIfNeeded()
            await loadPinned()
            if let currentUserId, !isE2EE {
                await services.liveShare.load(
                    conversationId: conversation.id,
                    currentUserId: currentUserId
                )
            }
            guard !Task.isCancelled, isOnScreen else { return }
            startSync()
            startActivePing()
        }
        .onDisappear {
            isOnScreen = false
            router.isDockHidden = false
            stopSync()
            stopActivePing(sendLeave: true)
            if let draftAutosaver { Task { await draftAutosaver.flush() } }
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            // Le flux SSE ne survit pas à la mise en arrière-plan : on le coupe
            // proprement et on resynchronise au retour — seulement si la
            // conversation est encore à l'écran.
            if phase == .active {
                guard isOnScreen else { return }
                startSync()
                startActivePing()
                Task { await refreshDelta() }
            } else {
                stopSync()
                stopActivePing(sendLeave: true)
                if let draftAutosaver { Task { await draftAutosaver.flush() } }
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

            // Avatar, nom et statut forment un seul élément VoiceOver : seule,
            // l'initiale masquée de l'avatar restait un texte non exposé. En
            // conversation chiffrée, le double-tap ouvre l'explication.
            HStack(spacing: SQSpace.md) {
                SQAvatar(
                    url: conversation.groupPhotoUrl ?? otherParticipantAvatarURL,
                    name: conversationTitle,
                    size: 42
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        // Deux lignes, puis réduction : en très grand texte, le nom
                        // était coupé.
                        Text(conversationTitle)
                            .font(SQFont.body(16, .semibold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .accessibilityIdentifier("conversation.title")
                        SQUserBadges(
                            badges: conversation.otherParticipantBadges(excluding: currentUserId),
                            size: 12
                        )
                    }
                    if otherIsOnline || isE2EE {
                        HStack(spacing: 4) {
                            if otherIsOnline {
                                Text("en ligne")
                                    .font(SQFont.body(12))
                                    .foregroundStyle(SQColor.success)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .accessibilityIdentifier("conversation.status")
                            }
                            // La limite du chiffrement reste visible dans la conversation
                            // même, et s'explique au toucher (SOC-07).
                            if isE2EE {
                                // Cible de 44 pt sans grandir l'en-tête : la marge
                                // appartient au bouton, puis est rendue à la mise en page.
                                Button { showEncryptionInfo = true } label: {
                                    Label("Chiffrée · texte seulement", systemImage: "lock.fill")
                                        .font(SQFont.body(12))
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, -14)
                                .accessibilityHint("Explique ce que protège le chiffrement")
                                .accessibilityIdentifier("conversation.encryption.info")
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .modifier(EncryptionInfoAction(isEnabled: isE2EE) { showEncryptionInfo = true })
            .sheet(isPresented: $showEncryptionInfo) { SQGlossarySheet(term: .endToEndEncryption) }

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
                    Image(systemName: "phone")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(networkPath.isOnline ? SQColor.label : SQColor.labelTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // CALL-OFFLINE-21 : grisé + désactivé hors-ligne (un appel
                // lancé sans réseau échouerait et ferait flasher l'écran).
                .disabled(!networkPath.isOnline)
                .accessibilityLabel("Appeler")
                .alert(
                    "Appel non chiffré de bout en bout",
                    isPresented: Binding(
                        get: { pendingTransportOnlyCall != nil },
                        set: { if !$0 { pendingTransportOnlyCall = nil } }
                    )
                ) {
                    Button("Appeler quand même") {
                        if let mode = pendingTransportOnlyCall { launchCall(mode: mode, endToEnd: false) }
                        pendingTransportOnlyCall = nil
                    }
                    Button("Annuler", role: .cancel) { pendingTransportOnlyCall = nil }
                } message: {
                    Text("Les messages de cette conversation restent chiffrés de bout en bout. L’appel, lui, ne l’est pas encore : il est protégé pendant le transport et passe par nos serveurs.")
                }
            }

            Menu {
                Button { showSearch = true } label: {
                    Label("Rechercher", systemImage: "magnifyingglass")
                }
                Button { showMedia = true } label: {
                    Label("Médias et fichiers", systemImage: "photo.on.rectangle")
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
                        Label("Signaler le profil", systemImage: "flag")
                    }
                    Button(role: .destructive) { confirmBlockOther = true } label: {
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
                    title: replyTitle(for: replyTarget),
                    text: displayedContent(for: replyTarget)
                ) { self.replyTarget = nil }
            }
            if let editTarget {
                quoteBar(title: "Modifier le message", text: displayedContent(for: editTarget)) {
                    self.editTarget = nil
                    restoreComposerAfterEdit()
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
                canSchedule: EncryptedConversationSurfaces.allowsScheduling(isV2: conversationIsV2),
                seedText: composerSeed,
                seedToken: composerSeedToken,
                ephemeralEnabled: $ephemeralEnabled,
                onTyping: { newValue in
                    // Le texte d'un message qu'on modifie n'est pas un brouillon.
                    if editTarget == nil { draftAutosaver?.textChanged(newValue) }
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
                onLiveShare: { showLiveShare = true },
                onPickPhoto: { item, caption in Task { await sendAttachment(item: item, caption: caption) } },
                onVoiceNote: { url, duration in Task { await sendVoiceNote(url: url, duration: duration) } },
                mentionSuggestions: mentionSuggestionProvider
            )
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(SQColor.surfaceGlass)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Clé « Répondre à %@ » : le titre construit en `String` cherchait
    /// « Répondre à Alice » dans le catalogue et restait en français.
    private func replyTitle(for message: MessageItem) -> LocalizedStringKey {
        if let name = message.sender?.displayName { return "Répondre à \(name)" }
        return "Répondre au message"
    }

    private func quoteBar(title: LocalizedStringKey, text: String, onClose: @escaping () -> Void) -> some View {
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

    private func messageBubble(_ message: MessageItem, isGroupStart: Bool = true, isGroupEnd: Bool = true) -> some View {
        let mine = (message.senderId == currentUserId)
        let reactions = reactionSummaries(for: message)
        let photoOnly = isPhotoOnlyMessage(message)
        return HStack(alignment: .bottom, spacing: SQSpace.sm) {
            if mine { Spacer(minLength: 72) }
            // Avatar de groupe : uniquement sur le DERNIER message d'une série
            // entrante ; les autres bulles réservent la largeur pour l'alignement.
            if !mine && conversation.isGroup {
                if isGroupEnd {
                    SQAvatar(url: message.sender?.avatarUrl, name: message.sender?.displayName ?? "?", size: 26)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: 26, height: 1)
                }
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs) {
                bubbleBody(for: message, mine: mine, isGroupStart: isGroupStart, photoOnly: photoOnly, reactions: reactions)
                if sendStatus[message.id] == .failed {
                    failedRetryRow(for: message)
                }
                threadReplyBadge(for: message)
            }
            if !mine { Spacer(minLength: 72) }
        }
    }

    /// Corps de bulle : contenu classique (texte/carte/sondage/fichier), photo
    /// seule (la photo EST la bulle) ou publication partagée seule (la carte
    /// EST la bulle — pas de cadre brique/surface autour), avec les réactions
    /// posées en capsules qui chevauchent légèrement le bas de la bulle.
    @ViewBuilder
    private func bubbleBody(for message: MessageItem, mine: Bool, isGroupStart: Bool, photoOnly: Bool, reactions: [MessageReactionSummary]) -> some View {
        Group {
            if photoOnly {
                attachmentsView(for: message, mine: mine, standalone: true)
            } else if let embed = sharedPostEmbedTarget(for: message) {
                standaloneSharedPostEmbed(message: message, card: embed.card, postId: embed.postId, mine: mine, isGroupStart: isGroupStart)
            } else {
                classicBubble(for: message, mine: mine, isGroupStart: isGroupStart)
            }
        }
        .sqShadowSoft()
        .opacity(sendStatus[message.id] == .sending ? 0.7 : 1)
        .contextMenu { contextMenu(for: message, mine: mine) }
        .overlay(alignment: mine ? .bottomTrailing : .bottomLeading) {
            reactionChips(for: message, summaries: reactions)
        }
        .padding(.bottom, reactions.isEmpty ? 0 : 13)
    }

    /// Message qui n'est QU'un partage de publication (embed interactif) :
    /// rendu sans fond de bulle — la carte est la bulle. On garde le chemin
    /// classique pour les messages supprimés, sans id de post ou en mode démo.
    private func sharedPostEmbedTarget(for message: MessageItem) -> (card: ShareCardData, postId: String)? {
        guard message.deletedAt == nil,
              !AppEnvironment.usesDemoData,
              let card = shareCard(for: message),
              let postId = card.socialPostId else { return nil }
        return (card, postId)
    }

    private func standaloneSharedPostEmbed(
        message: MessageItem,
        card: ShareCardData,
        postId: String,
        mine: Bool,
        isGroupStart: Bool
    ) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs) {
            if !mine, conversation.isGroup, isGroupStart, let name = message.sender?.displayName {
                Text(name)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            SharedPostEmbedBubble(
                card: card,
                postId: postId,
                mine: mine,
                standalone: true,
                service: services.feed,
                store: sharedPosts,
                onComment: { item in
                    lastSharedPostKey = postId
                    sharedPostComments = SharedPostCommentsTarget(id: postId, backendPostId: item.backendPostId)
                },
                onOpen: { item in
                    lastSharedPostKey = postId
                    sharedPostDetail = SharedPostDetailTarget(id: postId, item: item)
                }
            )
            // Heure discrète sous la carte (la carte n'a pas de zone méta).
            HStack(spacing: SQSpace.xs) {
                if let created = message.createdAt {
                    Text(created, format: .dateTime.hour().minute())
                }
                if message.editedAt != nil { Text("modifié") }
            }
            .font(SQFont.body(12, relativeTo: .caption2))
            .foregroundStyle(SQColor.labelSecondary)
            .accessibilityIdentifier("message.time")
        }
    }

    private func classicBubble(for message: MessageItem, mine: Bool, isGroupStart: Bool) -> some View {
            let card = shareCard(for: message)
            // Contenu interactif dans la bulle (embed de publication, photo
            // tappable) : on garde les éléments d'accessibilité séparés
            // (.contain) pour que VoiceOver atteigne les boutons ; sinon la
            // bulle reste UN élément combiné, comme avant.
            let hasInteractiveContent =
                (card?.socialPostId != nil && !AppEnvironment.usesDemoData)
                || message.attachments.contains { $0.url != nil && isImageAttachment($0) }
                // Aperçu d'un lien : VoiceOver doit pouvoir l'ouvrir.
                || (!isE2EE && message.deletedAt == nil && displayedContent(for: message).contains("http"))
            let spokenSummary = spokenTextSummary(for: message, mine: mine, card: card)
            return VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs + 1) {
                if !mine, conversation.isGroup, isGroupStart, let name = message.sender?.displayName {
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
                                // 0,6 donnait 2,82:1 : sous le seuil de 3:1 que
                                // WCAG 1.4.11 impose aux objets graphiques.
                                .fill(mine ? SQColor.onAccent.opacity(0.7) : SQColor.brandRed)
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
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                } else if let shareCard = card {
                    // Partage envoyé par Android (publication / signal / speedtest / session…).
                    // La publication (`social_post`) est testée EN PREMIER car elle peut
                    // aussi porter une mesure : elle se rend en publication réelle
                    // interactive (embed) quand l'id du post est connu, sinon en
                    // carte compacte statique.
                    if let postId = shareCard.socialPostId, !AppEnvironment.usesDemoData {
                        SharedPostEmbedBubble(
                            card: shareCard,
                            postId: postId,
                            mine: mine,
                            service: services.feed,
                            store: sharedPosts,
                            onComment: { item in
                                lastSharedPostKey = postId
                                sharedPostComments = SharedPostCommentsTarget(id: postId, backendPostId: item.backendPostId)
                            },
                            onOpen: { item in
                                lastSharedPostKey = postId
                                sharedPostDetail = SharedPostDetailTarget(id: postId, item: item)
                            }
                        )
                    } else if shareCard.kind.lowercased() == "social_post" {
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
                            .accessibilityIdentifier("message.text")
                        // Aperçu lu par le serveur : jamais dans une conversation chiffrée.
                        if !isE2EE, message.deletedAt == nil, text.contains("http") {
                            MessageLinkPreview(text: text, mine: mine)
                        }
                    }
                    if let transcription = transcriptions[message.id], !transcription.isEmpty {
                        transcriptionView(transcription, mine: mine)
                    }
                }
                // Heure en 12 pt et encre pleine : à 10,5 pt et 60 % d'opacité,
                // elle passait sous le contraste AA (SOC-31, TRX-12).
                HStack(spacing: SQSpace.xs) {
                    if let created = message.createdAt {
                        Text(created, format: .dateTime.hour().minute())
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                            .accessibilityIdentifier("message.time")
                    }
                    if message.expiresAt != nil && message.deletedAt == nil {
                        Image(systemName: "timer")
                            .font(.system(size: 11))
                            .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                            .accessibilityLabel("Message éphémère")
                    }
                    if message.editedAt != nil && message.deletedAt == nil {
                        Text("modifié")
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                            .accessibilityIdentifier("message.time.edited")
                    }
                    sendStatusIndicator(for: message)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .background(mine ? SQColor.brandRed : SQColor.surface, in: bubbleShape(mine: mine))
            // En OLED, bulle reçue et fond sont noirs : le liseré des cartes
            // la détache (SOC-26). Transparent hors OLED.
            .overlay {
                if !mine { bubbleShape(mine: false).stroke(SQOledPalette.cardStroke, lineWidth: 1) }
            }
            .modifier(SpokenBubble(summary: spokenSummary, interactive: hasInteractiveContent))
    }

    /// Ce que VoiceOver lit pour une bulle de texte : qui a écrit, le texte,
    /// puis l'heure. En conversation à deux, l'expéditeur n'était jamais
    /// annoncé (SOC-31). `nil` pour les contenus riches (carte, sondage,
    /// citation, pièce jointe), qui gardent leurs propres éléments.
    private func spokenTextSummary(for message: MessageItem, mine: Bool, card: ShareCardData?) -> String? {
        guard card == nil,
              message.attachments.isEmpty,
              quotedMessage(for: message) == nil,
              location(for: message) == nil,
              pollsByMessageId[message.id] == nil else { return nil }
        let sender = mine ? String(localized: "Toi") : (message.sender?.displayName ?? String(localized: "Membre"))
        let body = message.deletedAt != nil ? String(localized: "Message supprimé") : displayedContent(for: message)
        var parts = [String(localized: "\(sender) : \(body)")]
        if let transcription = transcriptions[message.id], !transcription.isEmpty { parts.append(transcription) }
        if let created = message.createdAt { parts.append(created.formatted(.dateTime.hour().minute())) }
        if message.deletedAt == nil {
            if message.editedAt != nil { parts.append(String(localized: "modifié")) }
            if message.expiresAt != nil { parts.append(String(localized: "Message éphémère")) }
        }
        if sendStatus[message.id] == .sending { parts.append(String(localized: "Envoi en cours")) }
        return parts.joined(separator: ", ")
    }

    /// Capsules de réactions posées, regroupées par emoji, chevauchant le bas de
    /// la bulle. Tap = toggle de MA réaction. Ma réaction = capsule teintée accent.
    @ViewBuilder
    private func reactionChips(for message: MessageItem, summaries: [MessageReactionSummary]) -> some View {
        if !summaries.isEmpty {
            HStack(spacing: SQSpace.xs) {
                ForEach(summaries) { reaction in
                    Button {
                        Haptics.selection()
                        Task { await toggleReaction(message: message, emoji: reaction.emoji) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(reaction.emoji)
                                .font(.system(size: 13))
                            if reaction.count > 1 {
                                Text("\(reaction.count)")
                                    .font(SQFont.body(12, .semibold))
                                    .foregroundStyle(reaction.mine ? SQColor.brandRed : SQColor.labelSecondary)
                            }
                        }
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 4)
                        .background {
                            // Base opaque `surface` (la capsule chevauche la bulle) ;
                            // ma réaction reçoit la teinte accentSoft par-dessus.
                            Capsule(style: .continuous)
                                .fill(SQColor.surface)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .fill(reaction.mine ? SQColor.accentSoft : Color.clear)
                                )
                        }
                        .sqShadowSoft()
                    }
                    .buttonStyle(.plain)
                    .disabled(isE2EE)
                    .accessibilityLabel(reaction.mine
                        ? String(localized: "Réaction \(reaction.emoji) : \(reaction.count), dont la tienne")
                        : String(localized: "Réaction \(reaction.emoji) : \(reaction.count)"))
                    .accessibilityHint(reaction.mine ? "Toucher pour retirer ta réaction" : "Toucher pour réagir aussi")
                }
            }
            .offset(y: 12)
            .padding(.horizontal, SQSpace.sm + 2)
        }
    }

    /// Statut d'envoi optimiste dans la ligne méta (MSG-API-01). En cours :
    /// spinner discret (la bulle passe aussi à 0.7 d'opacité). L'échec est porté
    /// par `failedRetryRow`, SOUS la bulle (le danger sur fond brique serait illisible).
    @ViewBuilder
    private func sendStatusIndicator(for message: MessageItem) -> some View {
        if sendStatus[message.id] == .sending {
            ProgressView()
                .controlSize(.mini)
                .tint(SQColor.onAccent.opacity(0.8))
                .accessibilityLabel("Envoi en cours")
        }
    }

    /// Échec d'envoi : capsule dangerSoft sous la bulle, tappable pour rejouer
    /// l'envoi (même Idempotency-Key, donc sans doublon serveur).
    private func failedRetryRow(for message: MessageItem) -> some View {
        HStack(spacing: SQSpace.xs) {
            Button {
                Haptics.medium()
                Task { await performSend(localId: message.id) }
            } label: {
                HStack(spacing: SQSpace.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Non envoyé · Renvoyer")
                        .font(SQType.micro.weight(.semibold))
                }
                .foregroundStyle(SQColor.dangerInk)
                .padding(.horizontal, SQSpace.sm + 2)
                .padding(.vertical, 5)
                .background(SQColor.dangerSoft, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message non envoyé. Renvoyer.")
            // Un message qui ne partira plus (exclu du groupe, conversation
            // supprimée) doit pouvoir s'effacer (SOC-04).
            Button {
                Haptics.selection()
                Task { await discardFailed(localId: message.id) }
            } label: {
                Text("Supprimer")
                    .font(SQType.micro.weight(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, SQSpace.sm)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Supprimer le message non envoyé")
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
                    Text("\(count) réponse")
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
                .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
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
        // Rangée d'emojis compacte en tête du menu contextuel : palette
        // horizontale native sur iOS 17+ (rendu type iMessage, dim léger, pas de
        // fond plein écran), boutons classiques en repli iOS 16.
        // Pas de réactions en conversation chiffrée tant qu'elles ne sont pas
        // chiffrées : la réaction s'affichait puis disparaissait avec une erreur
        // (SOC-07).
        if !isE2EE {
            if #available(iOS 17.0, *) {
                ControlGroup { reactionMenuButtons(for: message) }
                    .controlGroupStyle(.palette)
            } else {
                reactionMenuButtons(for: message)
            }
            Divider()
        }
        Button {
            // Quitter une modification pour répondre : le texte du message
            // modifié ne devient pas la réponse, le brouillon revient.
            if editTarget != nil {
                editTarget = nil
                restoreComposerAfterEdit()
            }
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
            // Pas de transcription dans une conversation chiffrée : elle suppose
            // que le serveur écoute l'audio (spec E2EE §13, refusée côté serveur
            // aussi). Un vocal peut y arriver en clair depuis une ancienne app.
            if message.hasVoiceNote, !isE2EE, transcriptions[message.id] == nil {
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
                pendingDeletion = PendingMessageDeletion(message: message, forEveryone: true)
            } label: {
                Label("Supprimer pour tous", systemImage: "trash")
            }
        }
        Button(role: .destructive) {
            pendingDeletion = PendingMessageDeletion(message: message, forEveryone: false)
        } label: {
            Label("Supprimer pour moi", systemImage: "trash.slash")
        }
        // Signaler un message, en 1:1 comme en groupe (Guideline 1.2, SOC-12).
        if !mine, message.deletedAt == nil, !message.id.hasPrefix("local-") {
            Divider()
            Button(role: .destructive) {
                reportTarget = message
            } label: {
                Label("Signaler le message", systemImage: "flag")
            }
        }
        // Blocage par expéditeur dans les groupes (Guideline 1.2) — en 1:1 le
        // blocage est déjà accessible depuis la barre d'outils.
        if !mine, conversation.isGroup, let senderId = message.senderId {
            Divider()
            Button(role: .destructive) {
                pendingBlockSenderId = senderId
            } label: {
                Label("Bloquer l’expéditeur", systemImage: "hand.raised")
            }
        }
    }

    /// Boutons de réaction du menu contextuel (toggle : re-taper retire MA réaction).
    @ViewBuilder
    private func reactionMenuButtons(for message: MessageItem) -> some View {
        ForEach(["❤️", "🔥", "👏", "🚀", "⚡", "📡"], id: \.self) { emoji in
            Button {
                Haptics.light()
                Task { await toggleReaction(message: message, emoji: emoji) }
            } label: {
                Text(emoji)
            }
            .accessibilityLabel("Réagir avec \(emoji)")
        }
    }

    @ViewBuilder
    private func attachmentsView(for message: MessageItem, mine: Bool, standalone: Bool = false) -> some View {
        ForEach(message.attachments.filter { $0.url != nil }) { attachment in
            if isImageAttachment(attachment) {
                attachmentImage(attachment, message: message, mine: mine, standalone: standalone)
            } else if isAudioAttachment(attachment), let url = attachment.url {
                // Lue dans l'app : elle s'ouvrait comme un fichier hors de l'app (SOC-06).
                RemoteVoiceNoteBubble(attachment: attachment, remoteURL: url, mine: mine)
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, SQSpace.xs)
            } else if let url = attachment.url {
                attachmentFileRow(attachment, url: url, mine: mine)
            }
        }
    }

    private func isImageAttachment(_ attachment: MessageAttachment) -> Bool {
        attachment.kind.uppercased() == "IMAGE" || (attachment.contentType?.hasPrefix("image/") ?? false)
    }

    private func isAudioAttachment(_ attachment: MessageAttachment) -> Bool {
        attachment.kind.uppercased() == "AUDIO" || (attachment.contentType?.hasPrefix("audio/") ?? false)
    }

    /// Vrai quand le message se réduit à UNE photo (sans légende ni carte de
    /// partage/sondage) : la photo est alors rendue comme bulle à part entière.
    private func isPhotoOnlyMessage(_ message: MessageItem) -> Bool {
        let visible = message.attachments.filter { $0.url != nil }
        guard visible.count == 1, isImageAttachment(visible[0]),
              message.deletedAt == nil,
              message.metadata == nil,
              displayedContent(for: message).isEmpty else { return false }
        return true
    }

    /// Photo envoyée : shimmer pendant le chargement, ratio préservé (max ~240 pt).
    /// Dans une bulle avec légende : coin 14. En « photo seule » : la photo
    /// remplit la bulle (coins de bulle) avec l'heure en surimpression.
    /// Tap : ouvre la photo en plein écran (MessageImageViewer).
    private func attachmentImage(_ attachment: MessageAttachment, message: MessageItem, mine: Bool, standalone: Bool) -> some View {
        let size = imageDisplaySize(for: attachment)
        let shape: AnyShape = standalone
            ? AnyShape(bubbleShape(mine: mine))
            : AnyShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        return Button {
            guard let url = attachment.url,
                  case .privateAccount(let accountSession) = privateImageCacheScope else { return }
            Haptics.selection()
            imageViewerTarget = MessageImageTarget(
                id: attachment.id ?? url.absoluteString,
                url: url,
                accountSession: accountSession
            )
        } label: {
            Group {
                if let privateImageCacheScope {
                    RemoteImage(
                        url: attachment.url,
                        maxDimension: 240,
                        contentMode: .fill,
                        cacheScope: privateImageCacheScope
                    ) {
                        Rectangle().fill(SQColor.surfaceMuted).sqShimmer()
                    }
                } else {
                    Rectangle().fill(SQColor.surfaceMuted)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(alignment: .bottomTrailing) {
                if standalone { photoTimeOverlay(for: message) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // « Photo envoyée » se disait aussi des photos reçues (SOC-31).
        .accessibilityLabel(mine
            ? String(localized: "Ta photo")
            : String(localized: "Photo de \(message.sender?.displayName ?? String(localized: "Membre"))"))
        .accessibilityHint("Toucher pour afficher en plein écran")
    }

    /// Taille d'affichage d'une photo : ratio préservé, plus grand côté ≤ 240 pt,
    /// plus petit côté ≥ 96 pt (repli carré 240 sans dimensions serveur).
    private func imageDisplaySize(for attachment: MessageAttachment) -> CGSize {
        guard let w = attachment.width, let h = attachment.height, w > 0, h > 0 else {
            return CGSize(width: 240, height: 240)
        }
        let scale = min(240 / CGFloat(max(w, h)), 1)
        return CGSize(
            width: max(96, CGFloat(w) * scale),
            height: max(96, CGFloat(h) * scale)
        )
    }

    /// Heure (+ éphémère) en surimpression bas-droit d'une photo seule, sur
    /// scrim léger. Noir/blanc volontaires : superposés à la photo, ils sont
    /// indépendants du thème (pas des couleurs d'UI).
    @ViewBuilder
    private func photoTimeOverlay(for message: MessageItem) -> some View {
        if let created = message.createdAt {
            HStack(spacing: SQSpace.xs) {
                if message.expiresAt != nil && message.deletedAt == nil {
                    Image(systemName: "timer")
                        .font(.system(size: 9))
                        .accessibilityLabel("Message éphémère")
                }
                Text(created, format: .dateTime.hour().minute())
                    .font(SQFont.body(12, .medium, relativeTo: .caption2))
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.32), in: Capsule(style: .continuous))
            .padding(SQSpace.sm)
        }
    }

    /// Pièce jointe non-image : rangée icône doc en pastille 36, nom + taille,
    /// bouton d'ouverture — tuile coin 14 dans la bulle.
    private func attachmentFileRow(_ attachment: MessageAttachment, url: URL, mine: Bool) -> some View {
        Link(destination: url) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                    .frame(width: 36, height: 36)
                    .background(mine ? SQColor.onAccent.opacity(0.16) : SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.fileName ?? String(localized: "Pièce jointe"))
                        .font(SQFont.body(13, .semibold))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                        .lineLimit(1)
                            .truncationMode(.middle)
                        .truncationMode(.middle)
                    Text(fileMetaLine(attachment))
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: SQSpace.sm)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(mine ? SQColor.onAccent.opacity(0.9) : SQColor.brandRed)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.sm)
            .frame(minWidth: 200, alignment: .leading)
            .background(mine ? SQColor.onAccent.opacity(0.10) : SQColor.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.fileName.map { String(localized: "Pièce jointe \($0), \(fileMetaLine(attachment))") }
            ?? String(localized: "Pièce jointe, \(fileMetaLine(attachment))"))
        .accessibilityHint("Toucher pour ouvrir")
    }

    /// « 1,2 Mo · PDF » — taille + extension lisibles sous le nom du fichier.
    private func fileMetaLine(_ attachment: MessageAttachment) -> String {
        var parts: [String] = []
        if let size = attachment.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let ext = attachment.fileName?.split(separator: ".").last.map(String.init),
           ext.count <= 5, !ext.isEmpty, attachment.fileName?.contains(".") == true {
            parts.append(ext.uppercased())
        }
        return parts.isEmpty ? "Fichier" : parts.joined(separator: " · ")
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
        if message.isEncrypted { return decryptedMessages[message.id] ?? String(localized: "🔒 Message chiffré") }
        let value = message.content ?? ""
        return value.isEmpty ? String(localized: "Pièce jointe") : value
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
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, SQSpace.xs)
            }
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if let typingUntil, typingUntil > Date() {
            HStack(alignment: .bottom, spacing: SQSpace.sm) {
                SQAvatar(
                    url: conversation.groupPhotoUrl ?? otherParticipantAvatarURL,
                    name: conversationTitle,
                    size: 24
                )
                .accessibilityHidden(true)
                TypingDotsView()
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm + 2)
                    .background(SQColor.surface, in: bubbleShape(mine: false))
                    .sqShadowSoft()
                Spacer(minLength: 0)
            }
            .padding(.bottom, SQSpace.xs)
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity),
                        removal: .opacity
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("En train d’écrire")
            // Disparition en douceur à l'échéance : sans ce timer, la condition
            // `typingUntil > Date()` n'était réévaluée qu'au prochain re-render.
            .task(id: typingUntil) {
                let remaining = typingUntil.timeIntervalSinceNow
                guard remaining > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
                    self.typingUntil = nil
                }
            }
        }
    }

    private func quotedMessage(for message: MessageItem) -> MessageItem? {
        guard let replyToId = message.replyToId else { return nil }
        return messages.first { $0.id == replyToId }
    }

    /// Horodatage de section centré (« Aujourd’hui 14:32 ») : affiché en tête de
    /// conversation, au changement de jour, ou après plus d'une heure de silence.
    private func sectionStamp(for message: MessageItem, previous: MessageItem?) -> String? {
        guard let date = message.createdAt else { return nil }
        if let previousDate = previous?.createdAt {
            let sameDay = Calendar.current.isDate(date, inSameDayAs: previousDate)
            guard !sameDay || date.timeIntervalSince(previousDate) > 3600 else { return nil }
        }
        // Même format que l'heure des bulles (« 00:04 », pas « 0:04 »).
        let time = date.formatted(.dateTime.hour().minute())
        // Traduits : l'app anglaise affichait « Aujourd’hui » et « Hier » (SOC-28).
        if Calendar.current.isDateInToday(date) { return String(localized: "Aujourd’hui \(time)") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Hier \(time)") }
        return "\(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) \(time)"
    }

    /// Dernier message d'un groupe du même auteur (porte l'avatar en groupe entrant).
    private func isGroupEnd(_ message: MessageItem, next: MessageItem?) -> Bool {
        guard let next else { return true }
        if next.senderId != message.senderId { return true }
        return sectionStamp(for: next, previous: message) != nil
    }

    /// Saut vers le message cité : défilement animé + surbrillance transitoire.
    private func jumpToQuoted(_ message: MessageItem) {
        Haptics.selection()
        scrollTargetId = message.id
        highlightMessage(message.id)
    }

    private func highlightMessage(_ id: String) {
        withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { highlightedMessageId = id }
        Task {
            try? await Task.sleep(nanoseconds: 850_000_000)
            await MainActor.run {
                if highlightedMessageId == id {
                    withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { highlightedMessageId = nil }
                }
            }
        }
    }

    private func reactionSummaries(for message: MessageItem) -> [MessageReactionSummary] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var mine: Set<String> = []
        for reaction in message.reactions {
            if counts[reaction.emoji] == nil {
                order.append(reaction.emoji)
            }
            counts[reaction.emoji, default: 0] += 1
            if reaction.userId == currentUserId { mine.insert(reaction.emoji) }
        }
        return order.map {
            MessageReactionSummary(emoji: $0, count: counts[$0, default: 0], mine: mine.contains($0))
        }
    }

    private func displayedContent(for message: MessageItem) -> String {
        if message.deletedAt != nil { return "" }
        if message.isEncrypted { return decryptedMessages[message.id] ?? String(localized: "🔒 Message chiffré") }
        return message.content ?? ""
    }

    /// Carte de partage (signal/speedtest/session/social) portée par le metadata —
    /// envoyée par Android. Le metadata des cartes est en clair même en E2EE. La
    /// garde `metadata != nil` évite tout parsing JSON sur les messages texte.
    /// PERF-MSG-03 — le parsing (JSONSerialization + tri) est mémoïsé par message
    /// dans `renderCache` : appelé jusqu'à deux fois par bulle porteuse dans le
    /// chemin de rendu, il ne s'exécute désormais qu'une fois par message.
    private func shareCard(for message: MessageItem) -> ShareCardData? {
        guard message.deletedAt == nil, message.metadata != nil else { return nil }
        return renderCache.shareCard(for: message)
    }

    /// Localisation partagée (kind LOCATION) portée par le metadata. PERF-MSG-03 —
    /// parsing mémoïsé par message (cf. `shareCard(for:)`).
    private func location(for message: MessageItem) -> MessageLocationData? {
        guard message.deletedAt == nil, message.metadata != nil else { return nil }
        return renderCache.location(for: message)
    }

    /// Au retour d'un sheet (commentaires / publication complète), rafraîchit
    /// silencieusement l'embed pour resynchroniser les compteurs.
    private func refreshSharedPostAfterSheet() {
        guard let key = lastSharedPostKey else { return }
        lastSharedPostKey = nil
        sharedPosts.refresh(key)
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    // MARK: Chargement / sync

    /// Conversation v2 lue et écrite par la messagerie v2 (verrous ouverts).
    private var usesV2: Bool { conversationIsV2 && services.e2eeV2Messaging.readsEnabled }
    /// Conversation v2 que cette version n'ouvre pas (verrous fermés) : rien
    /// n'y part, et surtout pas sous l'ancienne clé v1 (§12).
    private var v2Unavailable: Bool { conversationIsV2 && !usesV2 }

    private struct SafetyNumberPeer: Identifiable {
        let userId: String
        let name: String?
        var id: String { userId }
    }

    private func v2NoticeLabel(_ notice: E2EEV2ThreadPresentation.Notice, detail: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(notice.text)
                if let detail {
                    Text(detail)
                        .fontWeight(.semibold)
                        .foregroundStyle(SQColor.accentInk)
                }
            }
        } icon: {
            Image(systemName: "lock.trianglebadge.exclamationmark")
        }
        .font(SQType.caption)
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity, minHeight: detail == nil ? nil : 44, alignment: .leading)
        .padding(.vertical, SQSpace.xs)
        .contentShape(Rectangle())
    }

    /// Relève v2 : chaîne, époques, liste vérifiée, puis le fil présenté. Les
    /// bulles locales en cours d'envoi restent jusqu'à leur accusé.
    private func loadV2() async {
        switch await services.e2eeV2Messaging.thread(
            conversationId: conversation.id, isGroup: conversation.isGroup, participants: conversation.participants
        ) {
        case .thread(let presentation):
            let localPending = messages.filter { pendingSends[$0.id] != nil }
            messages = Self.normalized(presentation.messages + localPending)
            v2Notices = presentation.notices
            errorMessage = nil
        case .failure(let failure):
            errorMessage = failure.kind == .retryable
                ? String(localized: "Connexion instable. La conversation chiffrée se mettra à jour dès que possible.")
                : String(localized: "Cette conversation chiffrée n’a pas pu être lue pour l’instant.")
        }
    }

    /// Envoi v2 d'un texte, d'une édition ou d'une suppression, sous le même
    /// identifiant à chaque essai : jamais deux signatures pour un message.
    private func sendV2(_ body: E2EEV2ContentPayloadV2.Body, replyToId: String?, ttlSeconds: Int, clientRequestId: String) async -> Bool {
        let result = await services.e2eeV2Messaging.send(
            .init(body: body, replyToRef: replyToId, mentions: [], ttlSeconds: ttlSeconds),
            clientRequestId: clientRequestId, conversationId: conversation.id, isGroup: conversation.isGroup,
            participantIds: conversation.participants.map(\.userId)
        )
        switch result {
        case .sent, .alreadyAccepted:
            await loadV2()
            return true
        case .capabilityMissing:
            showActionError(String(localized: "Un membre doit mettre à jour SignalQuest pour recevoir ce message. Il partira dès que possible."))
        case .membersNotTrusted:
            showActionError(String(localized: "Un membre a un nouveau numéro de sécurité. Vérifie-le avant d’envoyer."))
        case .needsEpoch, .needsRotation:
            showActionError(String(localized: "La conversation chiffrée se met à jour. Réessaie dans un instant."))
        case .failure(let failure):
            showActionError(failure.kind == .retryable
                ? String(localized: "Connexion instable. Réessaie.")
                : String(localized: "Ce message chiffré n’a pas pu être envoyé."))
        }
        return false
    }

    private func load() async {
        if AppEnvironment.usesDemoData {
            messages = conversation.lastMessage.map { [$0] } ?? MessageItem.demo
            errorMessage = nil
            return
        }
        // La reprise ne doit jamais retarder l'ouverture de la conversation. Le backend
        // deduplique par clientRequestId si deux ouvertures reveillent la meme ligne.
        Task {
            await service.retryPendingTextMessages()
            await service.retryPendingAttachments()
        }
        do {
            let page = try await service.messages(conversationId: conversation.id, cursor: nil)
            // Les bulles locales encore en cours d'envoi (ou en échec, rejouables)
            // ne sont pas encore sur le serveur : un rechargement ne doit pas les
            // faire disparaître.
            let localPending = messages.filter { pendingSends[$0.id] != nil }
            messages = Self.normalized(page.messages + localPending + (await restoredFailedMessages()))
            olderCursor = (page.hasMore ?? (page.nextCursor != nil)) ? page.nextCursor : nil
            readReceipts = page.readReceipts ?? []
            errorMessage = nil
            advanceLastSync(with: page.messages)
            await refreshE2EEState()
            await decryptLoadedMessages()
            refreshPolls()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Erreur d'une action (envoi, réaction, appel…) : bandeau passager. Seul
    /// l'échec du chargement affiche « Messages indisponibles », dont le bouton
    /// recharge la conversation ; une erreur d'appel s'y retrouvait (SOC-14).
    private func showActionError(_ message: String) {
        inAppNotifications.showError(message)
    }

    /// Signalement d'un message (SOC-12). En conversation chiffrée, la clé de
    /// la conversation part chiffrée pour la seule modération, comme sur le
    /// web ; la feuille le dit avant l'envoi.
    private func report(_ message: MessageItem, reason: ReportReason, comment: String?) async throws {
        if usesV2 {
            // §11 : rapport scellé pour la seule clé de modération, sans clé de conversation.
            try await services.e2eeV2Messaging.report(refs: [message.id], reason: reason, conversationId: conversation.id)
            inAppNotifications.show(SQInAppNotificationItem(
                body: String(localized: "Signalement envoyé. Merci, l’équipe de modération va l’examiner."),
                variant: .success
            ))
            return
        }
        var wrappedKey: String?
        if isE2EE {
            guard let e2ee else { throw E2EEError.locked }
            wrappedKey = try await e2ee.moderationWrappedConversationKey(conversationId: conversation.id)
        }
        try await service.reportMessages(
            messageIds: [message.id],
            reason: reason.rawValue,
            details: comment,
            moderationWrappedKeyB64: wrappedKey
        )
        // Sans clé de modération côté serveur, le signalement part quand même,
        // mais le message chiffré restera illisible pour l'équipe : on le dit.
        let readable = !isE2EE || wrappedKey != nil
        inAppNotifications.show(SQInAppNotificationItem(
            body: readable
                ? String(localized: "Signalement envoyé. Merci, l’équipe de modération va l’examiner.")
                : String(localized: "Signalement envoyé. Ce message étant chiffré, l’équipe de modération ne pourra pas en lire le contenu."),
            variant: .success
        ))
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
        // La borne suit uniquement les dates SERVEUR des messages reçus. Partir de
        // l'horloge du téléphone faisait sauter, à un appareil en avance, les
        // messages arrivés entre l'heure serveur et la sienne (SOC-40). Sans
        // message, elle reste à `.distantPast` et le prochain rafraîchissement
        // recharge la page, ce qui est sans coût pour une conversation vide.
        var bound = lastSync
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
                        withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { typingUntil = Date().addingTimeInterval(5) }
                    }
                case .viewingEvent:
                    await refreshViewers()
                case .stateEvent:
                    await refreshLatestPageState()
                case .serverEvent, .polling:
                    if usesV2 { await loadV2() } else { await refreshDelta() }
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
            withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { conversationViewers = viewers }
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
            SQDiagnostics.record(error, area: .messageSync)
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
        if messages.contains(where: { $0.id == messageId }) {
            revealMessage(messageId)
            return
        }
        // Message plus ancien que les pages chargées : on remonte l'historique
        // jusqu'à lui (dix pages au plus), puis on y défile. Recharger la
        // première page ne menait à rien (SOC-21).
        Task {
            var pages = 0
            while !messages.contains(where: { $0.id == messageId }), olderCursor != nil, pages < 10 {
                while isLoadingOlder { try? await Task.sleep(for: .milliseconds(100)) }
                await loadOlder()
                pages += 1
            }
            guard messages.contains(where: { $0.id == messageId }) else {
                showActionError(String(localized: "Ce message est trop ancien pour être affiché ici."))
                return
            }
            // Laisse le réancrage de l'historique inséré se faire avant de défiler.
            try? await Task.sleep(for: .milliseconds(150))
            revealMessage(messageId)
        }
    }

    private func revealMessage(_ id: String) {
        scrollTargetId = id
        highlightMessage(id)
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
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
    }

    private func unpin(message: MessageItem) async {
        do {
            try await service.unpin(conversationId: conversation.id, messageId: message.id)
            pinnedMessages.removeAll { $0.messageId == message.id }
            Haptics.success()
        } catch {
            showActionError(error.userFacingMessage)
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
                showActionError(String(localized: "Aucune transcription disponible pour ce message."))
            }
        } catch {
            showActionError(error.userFacingMessage)
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
            let updated = try await service.votePoll(
                pollId: pollId,
                optionIds: optionIds,
                in: conversation
            )
            pollsByMessageId[messageId] = mergePollTexts(updated, messageId: messageId)
            Haptics.selection()
        } catch {
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
    }

    private func closePoll(messageId: String, pollId: String) async {
        do {
            let updated = try await service.closePoll(pollId: pollId, in: conversation)
            pollsByMessageId[messageId] = mergePollTexts(updated, messageId: messageId)
            Haptics.success()
        } catch {
            showActionError(error.userFacingMessage)
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

    /// Remet le brouillon de la conversation dans le champ, à l'ouverture.
    private func restoreDraftIfNeeded() async {
        guard draftAutosaver == nil else { return }
        let autosaver = MessageDraftAutosaver(conversationId: conversation.id)
        draftAutosaver = autosaver
        if let draft = await autosaver.load(), editTarget == nil {
            seedComposer(draft)
        }
    }

    /// Fin d'une modification : le brouillon d'avant revient dans le champ.
    private func restoreComposerAfterEdit() {
        seedComposer(draftAutosaver?.text ?? "")
    }

    private func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // L'édition n'est pas optimiste : on attend la confirmation serveur
        // avant de remplacer le texte affiché (recharge pour réordonner).
        if let editTarget, usesV2 {
            isSending = true
            defer { isSending = false }
            if await sendV2(.edit(targetRef: editTarget.id, text: text), replyToId: nil, ttlSeconds: 0,
                            clientRequestId: UUID().uuidString) {
                self.editTarget = nil
                restoreComposerAfterEdit()
                Haptics.success()
            } else {
                Haptics.error()
            }
            return
        }
        if let editTarget {
            isSending = true
            defer { isSending = false }
            do {
                try await service.editMessage(messageId: editTarget.id, text: text, in: conversation, e2ee: e2ee)
                decryptedMessages[editTarget.id] = text
                self.editTarget = nil
                restoreComposerAfterEdit()
                await load()
                Haptics.success()
            } catch {
                showActionError(error.userFacingMessage)
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
        draftAutosaver?.discard()
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
        guard !v2Unavailable else {
            sendStatus[localId] = .failed
            return
        }
        sendStatus[localId] = .sending
        if usesV2 {
            // Même clientRequestId à chaque essai : l'enveloppe gardée repart à l'octet.
            if await sendV2(.text(pending.text), replyToId: pending.replyToId, ttlSeconds: pending.ttlSeconds,
                            clientRequestId: pending.idempotencyKey) {
                messages.removeAll { $0.id == localId }
                sendStatus[localId] = nil
                pendingSends[localId] = nil
                Haptics.success()
            } else {
                withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { sendStatus[localId] = .failed }
                Haptics.error()
            }
            return
        }
        do {
            let sent = pending.restored
                ? try await service.resendPendingText(clientRequestId: pending.idempotencyKey)
                : try await service.sendText(
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
            // Premier message envoyé : le bon moment pour proposer d'être
            // prévenu des réponses (TRX-01), une seule fois par appareil.
            Task { await services.notificationPriming.considerPriming(after: .messageSent) }
        } catch {
            // On conserve la bulle et les données de rejeu : l'utilisateur peut
            // réessayer d'un tap. Pas de bannière d'erreur globale ici — le
            // feedback est porté par la bulle elle-même.
            withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { sendStatus[localId] = .failed }
            Haptics.error()
        }
    }

    /// Construit une bulle locale en clair (jamais persistée) affichée le temps
    /// de l'aller-retour serveur. Non chiffrée : `displayedContent` lit
    /// directement `content`, ce qui évite tout décryptage pour la bulle locale.
    /// Messages refusés restés dans la file d'envoi durable : ils disparaissaient
    /// en quittant la conversation, alors que la file les gardait (SOC-04).
    private func restoredFailedMessages() async -> [MessageItem] {
        let known = Set(pendingSends.values.map(\.idempotencyKey))
        var restored: [MessageItem] = []
        for record in await service.pendingTextMessages(conversationId: conversation.id)
        where record.failureReason != nil && !known.contains(record.clientRequestId) {
            let localId = "local-\(record.clientRequestId)"
            let text = record.request.content ?? ""
            pendingSends[localId] = PendingSend(
                text: text, replyToId: record.request.replyToId, idempotencyKey: record.clientRequestId,
                ttlSeconds: record.request.ttlSeconds ?? 0, restored: true
            )
            sendStatus[localId] = .failed
            let shown = record.request.e2ee != nil ? String(localized: "Message chiffré non envoyé") : text
            restored.append(makeOptimisticMessage(id: localId, text: shown, replyToId: record.request.replyToId, createdAt: record.createdAt))
        }
        return restored
    }

    /// « Supprimer » sur un message non envoyé : il quitte aussi la file durable.
    private func discardFailed(localId: String) async {
        if let pending = pendingSends[localId] {
            await service.discardPendingText(clientRequestId: pending.idempotencyKey)
        }
        pendingSends[localId] = nil
        sendStatus[localId] = nil
        withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { messages.removeAll { $0.id == localId } }
    }

    private func makeOptimisticMessage(id: String, text: String, replyToId: String?, ttlSeconds: Int = 0, createdAt: Date = Date()) -> MessageItem {
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
            createdAt: createdAt,
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

    /// Envoie une note vocale.
    ///
    /// Même chemin que les autres pièces jointes : `uploadAttachment` accepte un
    /// `mimeType` arbitraire, et le backend reconnaît `audio/*` pour déclencher
    /// la transcription de son côté.
    ///
    /// Le fichier du recorder est supprimé dans tous les cas ; le service en copie d'abord le
    /// contenu dans son outbox protégée, donc un échec ou kill processus reste reprenable.
    private func sendVoiceNote(url: URL, duration: TimeInterval) async {
        defer { try? FileManager.default.removeItem(at: url) }
        isSending = true
        defer { isSending = false }
        do {
            // Même limite que les images : le chiffrement des pièces jointes
            // n'est pas encore disponible partout. Le dire plutôt que d'envoyer
            // un audio en clair dans une conversation chiffrée.
            guard !isE2EE else {
                throw E2EEError.unsupported("Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils.")
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            let sent = try await service.sendAttachmentData(
                data,
                filename: url.lastPathComponent,
                mimeType: "audio/m4a",
                kind: "AUDIO",
                caption: "",
                width: nil,
                height: nil,
                in: conversation,
                replyToId: replyTarget?.id,
                e2ee: e2ee
            )
            messages = Self.normalized(messages + [sent])
            replyTarget = nil
            Haptics.success()
        } catch {
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
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
            let caption = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
            let sent = try await service.sendAttachmentData(
                prepared.data,
                filename: "photo.jpg",
                mimeType: "image/jpeg",
                kind: "IMAGE",
                caption: caption,
                width: prepared.width,
                height: prepared.height,
                in: conversation,
                replyToId: replyTarget?.id,
                e2ee: e2ee
            )
            messages = Self.normalized(messages + [sent])
            if sent.isEncrypted, !caption.isEmpty {
                decryptedMessages[sent.id] = caption
            }
            // La légende envoyée ne doit pas revenir comme brouillon.
            draftAutosaver?.discard()
            clearComposer()
            replyTarget = nil
            Haptics.success()
        } catch {
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
    }

    /// Recompresse l'image en JPEG ≤ 1280 px qualité 0,85 (HEIC converti
    /// d'office) — même normalisation qu'Android avant upload.
    nonisolated private static func preparedJPEG(from data: Data) -> (data: Data, width: Int, height: Int)? {
        // Décodage réduit directement à 1 280 px. L'ancien chemin décodait la photo
        // en pleine taille puis la redessinait à l'échelle de l'écran (×3) : le
        // JPEG envoyé faisait environ 3 840 px pour 1 280 annoncés (SOC-36).
        guard let image = ImagePipeline.downsample(data: data, maxPixel: 1280),
              let cgImage = image.cgImage,
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return (jpeg, cgImage.width, cgImage.height)
    }

    private func toggleReaction(message: MessageItem, emoji: String) async {
        let alreadyMine = message.reactions.contains { $0.emoji == emoji && $0.userId == currentUserId }
        // Affichage immédiat : la réaction n'apparaissait qu'au rechargement
        // suivant, car le delta ne renvoie pas les réactions (SOC-05).
        if let uid = currentUserId {
            var updated = message
            if alreadyMine {
                updated.reactions.removeAll { $0.emoji == emoji && $0.userId == uid }
            } else {
                updated.reactions.append(MessageReaction(emoji: emoji, userId: uid))
            }
            messages = messages.map { $0.id == message.id ? updated : $0 }
        }
        do {
            if alreadyMine {
                try await service.removeReaction(
                    messageId: message.id,
                    emoji: emoji,
                    in: conversation
                )
            } else {
                try await service.react(
                    messageId: message.id,
                    emoji: emoji,
                    in: conversation
                )
            }
            await refreshLatestPageState()
        } catch {
            // Échec : on remet l'état d'avant plutôt que d'afficher une
            // réaction que le serveur n'a pas enregistrée.
            messages = messages.map { $0.id == message.id ? message : $0 }
            showActionError(error.userFacingMessage)
        }
    }

    /// Réactions, votes et accusés de lecture ne passent pas par le delta, qui ne
    /// renvoie que les messages nouveaux ou modifiés : sur un événement d'état, on
    /// relit la dernière page et on met à jour les messages affichés, en gardant
    /// les bulles locales encore en attente (SOC-05).
    private func refreshLatestPageState() async {
        guard !AppEnvironment.usesDemoData else { return }
        do {
            let page = try await service.messages(conversationId: conversation.id, cursor: nil)
            let fresh = Self.normalized(page.messages)
            messages = Self.normalized(messages + fresh)
            if let receipts = page.readReceipts { readReceipts = receipts }
            advanceLastSync(with: fresh)
            await decryptLoadedMessages()
            refreshPolls()
        } catch {
            MessageSyncLog.logger.error("état erreur: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func delete(message: MessageItem, forEveryone: Bool) async {
        if v2Unavailable && forEveryone { return }
        if usesV2 {
            // v2 : « pour tous » est une suppression signée (§5) ; « pour moi » reste local.
            if forEveryone {
                _ = await sendV2(.delete(targetRef: message.id), replyToId: nil, ttlSeconds: 0, clientRequestId: UUID().uuidString)
            } else {
                messages.removeAll { $0.id == message.id }
            }
            return
        }
        do {
            try await service.deleteMessage(messageId: message.id, forEveryone: forEveryone)
            if forEveryone {
                await load()
            } else {
                messages.removeAll { $0.id == message.id }
            }
        } catch {
            showActionError(error.userFacingMessage)
        }
    }

    private func markRead() async {
        // L'état de lecture d'une conversation v2 arrive avec le lot serveur A7.
        guard !usesV2, let last = messages.last else { return }
        try? await service.markRead(conversationId: conversation.id, lastMessageId: last.id)
        // Le badge restait allumé jusqu'au prochain rafraîchissement (SOC-23).
        await services.refreshInboxBadge(force: true)
    }

    // MARK: Partage de position (parité Android)

    private func sendCurrentLocation() async {
        guard !isSharingLocation else { return }
        isSharingLocation = true
        defer { isSharingLocation = false }
        guard let owner = LocalAccountScope.sessionSnapshot() else {
            showActionError(String(localized: "Position indisponible"))
            Haptics.error()
            return
        }
        let expectedSessionID = services.api.credentials.snapshot().sessionID
        guard let location = await services.location.currentLocation(maxAge: 30) else {
            showActionError(String(localized: "Position indisponible — autorise la localisation dans les réglages."))
            Haptics.error()
            return
        }
        let place = await reverseGeocodedName(location)
        guard !Task.isCancelled, owner.isCurrent,
              services.api.credentials.snapshot().sessionID == expectedSessionID else { return }
        guard services.location.isUsable(location, maxAge: 30) else {
            showActionError(String(localized: "Position indisponible"))
            Haptics.error()
            return
        }
        do {
            let sent = try await service.sendLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                place: place,
                accuracyMeters: location.horizontalAccuracy,
                observedAt: location.timestamp,
                in: conversation,
                expectedSessionID: expectedSessionID,
                validateBeforeSend: { [locationService = services.location] in
                    try Task.checkCancellation()
                    let usable = await locationService.isUsable(location, maxAge: 30)
                    guard owner.isCurrent, usable else { throw APIError.cancelled }
                }
            )
            messages = Self.normalized(messages + [sent])
            Haptics.success()
        } catch {
            guard owner.isCurrent, !error.isCancellation else { return }
            showActionError(error.userFacingMessage)
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
            showActionError(error.userFacingMessage)
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
        let verifiedV2: Bool
        if isE2EE {
            verifiedV2 = services.callManager.canStartEncryptedCall(conversationId: conversation.id)
        } else {
            verifiedV2 = true
        }
        guard conversation.participants.count >= 2 else {
            showActionError(String(localized: "Aucun autre participant n’est disponible pour cet appel."))
            Haptics.error()
            return
        }
        guard CallLifecyclePolicy.canStartCall(participantCount: conversation.participants.count) else {
            showActionError(String(localized: "Les appels de groupe sont limités à 8 participants."))
            Haptics.error()
            return
        }
        switch CallLifecyclePolicy.outgoingCallMode(
            conversationE2EE: isE2EE, conversationV2: EncryptedConversationSurfaces.isV2(conversation), verifiedV2: verifiedV2
        ) {
        case .standard: launchCall(mode: mode, endToEnd: false)
        case .endToEnd: launchCall(mode: mode, endToEnd: true)
        case .confirmTransportOnly: pendingTransportOnlyCall = mode
        case .unavailable:
            showActionError(String(localized: "Cette conversation n’accepte que des appels chiffrés de bout en bout, et ils ne sont pas encore prêts sur cet appareil. Réessaie plus tard."))
            Haptics.error()
        }
    }

    private func launchCall(mode: String, endToEnd: Bool) {
        services.callManager.startOutgoingCall(
            conversationId: conversation.id,
            mode: mode,
            displayName: conversationTitle,
            requiresE2EE: endToEnd,
            isEncryptedConversation: isE2EE
        )
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
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
    }

    /// Bloque l'expéditeur d'un message de groupe (Guideline 1.2).
    private func blockSender(userId: String) async {
        do {
            try await services.friends.block(userId: userId)
            Haptics.success()
        } catch {
            showActionError(error.userFacingMessage)
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
            withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { needsKeyResync = true }
            return
        } catch {
            // §13 : aucun identifiant de message en clair dans les journaux.
            MessageSyncLog.logger.error("decrypt \(pending[0].id, privacy: .private) erreur: \(error.localizedDescription, privacy: .private)")
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

// MARK: - Partage GPS/radio en direct

/// Résumé compact épinglé au-dessus du composer. Il ne montre que les trois
/// sessions les plus récentes pour ne pas écraser la conversation dans un groupe ;
/// la sheet de gestion conserve la liste complète.
private struct LiveShareConversationBar: View {
    @ObservedObject var coordinator: ConversationLiveShareCoordinator
    let conversation: MessageConversation
    let currentUserId: String
    let onManage: () -> Void

    private var sessions: [LiveShareSession] {
        coordinator.sessions(for: conversation.id)
    }

    var body: some View {
        if !sessions.isEmpty || coordinator.errorMessage != nil {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                // Toute la ligne ouvre la gestion : une cible de 44 pt sans
                // agrandir le seul mot « Gérer » (34 × 16 pt en brique, SOC-31).
                Button(action: onManage) {
                    HStack(spacing: SQSpace.sm) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(SQColor.brandRed)
                            .accessibilityHidden(true)
                        Text("Partage en direct")
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            .accessibilityIdentifier("liveshare.title")
                        Spacer()
                        Text("Gérer")
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .fixedSize()
                            .accessibilityIdentifier("liveshare.manage.label")
                    }
                    // Cible de 44 pt, marge rendue ensuite à la mise en page :
                    // la barre garde sa hauteur.
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -14)
                .accessibilityLabel("Gérer le partage en direct")
                .accessibilityIdentifier("liveshare.manage")

                ForEach(sessions.prefix(3)) { session in
                    TimelineView(.periodic(from: .now, by: 5)) { timeline in
                        HStack(spacing: SQSpace.sm) {
                            Circle()
                                .fill(session.status != "active" ? SQColor.brandRed :
                                      LiveShareLocationFreshness.isCurrent(
                                          coordinator.payload(for: session.id), at: timeline.date
                                      ) ? SQColor.success : SQColor.warning)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary(for: session))
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(2)
                                if let detail = detail(for: session, at: timeline.date) {
                                    Text(detail)
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: SQSpace.xs)
                            action(for: session)
                        }
                    }
                }
                if sessions.count > 3 {
                    Text("+ \(sessions.count - 3) autre(s) session(s)")
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let error = coordinator.errorMessage {
                    Text(error)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("liveshare.error")
                }
            }
            .padding(SQSpace.sm + 2)
            .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(SQColor.separator, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func action(for session: LiveShareSession) -> some View {
        if session.status == "pending", session.sharerId == currentUserId {
            Button("Répondre", action: onManage)
                .font(SQType.micro.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(SQColor.brandRed)
                .controlSize(.small)
                .frame(minHeight: 44)
        } else {
            Button {
                Task { await coordinator.stop(sessionId: session.id) }
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .foregroundStyle(SQColor.brandRed)
            .disabled(coordinator.isBusy)
            .accessibilityLabel(session.status == "pending" ? "Annuler la demande" : "Arrêter le partage")
        }
    }

    private func summary(for session: LiveShareSession) -> String {
        if session.status == "pending" {
            return session.sharerId == currentUserId
                ? String(localized: "\(name(for: session.requesterId)) demande ta position")
                : String(localized: "Demande envoyée à \(name(for: session.sharerId))")
        }
        // Tutoiement et traduction, comme le reste de l'app (SOC-28).
        return session.sharerId == currentUserId
            ? String(localized: "Tu partages avec \(name(for: session.requesterId))")
            : String(localized: "\(name(for: session.sharerId)) partage avec toi")
    }

    private func detail(for session: LiveShareSession, at now: Date) -> String? {
        guard session.status == "active" else { return String(localized: "En attente de réponse") }
        let payload = coordinator.payload(for: session.id)
        if payload?.location != nil,
           !LiveShareLocationFreshness.isCurrent(payload, at: now) {
            return String(localized: "Position indisponible")
        }
        if payload?.location == nil, payload?.radio != nil {
            return String(localized: "GPS indisponible, données réseau reçues.")
        }
        let radio = payload?.radio
        let parts = [
            radio?.displayOperatorName,
            radio?.technology ?? radio?.connectionType,
            radio?.band.map { SQUnits.band($0, technology: radio?.technology) },
            radio?.rsrp.map { "RSRP \($0) dBm" }
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return payload?.location == nil
            ? String(localized: "En attente de la première position…")
            : String(localized: "Position partagée")
    }

    private func name(for userId: String) -> String {
        if userId == currentUserId { return String(localized: "toi") }
        if let name = conversation.participants.first(where: { $0.userId == userId })?.user.displayName,
           !name.isEmpty { return name }
        return "un participant"
    }
}

private struct LiveShareManagementSheet: View {
    @ObservedObject var coordinator: ConversationLiveShareCoordinator
    let conversation: MessageConversation
    let currentUserId: String

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var mode: String
    @State private var selectedTargetId: String
    @State private var selectedBroadcastIds: Set<String>

    init(
        coordinator: ConversationLiveShareCoordinator,
        conversation: MessageConversation,
        currentUserId: String
    ) {
        self.coordinator = coordinator
        self.conversation = conversation
        self.currentUserId = currentUserId
        let targets = conversation.participants.filter { $0.userId != currentUserId }
        _mode = State(initialValue: conversation.isGroup ? "broadcast" : "targeted")
        _selectedTargetId = State(initialValue: targets.first?.userId ?? "")
        _selectedBroadcastIds = State(initialValue: Set(targets.map(\.userId)))
    }

    private var targets: [ConversationParticipant] {
        conversation.participants.filter { $0.userId != currentUserId }
    }

    private var sessions: [LiveShareSession] {
        coordinator.sessions(for: conversation.id)
    }

    private var canSubmit: Bool {
        guard !coordinator.isBusy else { return false }
        guard conversation.isGroup else { return !targets.isEmpty }
        return mode == "targeted" ? !selectedTargetId.isEmpty : !selectedBroadcastIds.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    disclosure

                    if !sessions.isEmpty {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            Text("Sessions en cours")
                                .font(SQType.heading)
                                .foregroundStyle(SQColor.label)
                            ForEach(sessions) { session in
                                LiveShareSessionCard(
                                    coordinator: coordinator,
                                    session: session,
                                    conversation: conversation,
                                    currentUserId: currentUserId
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        Text("Nouveau partage")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)

                        if conversation.isGroup {
                            Picker("Destinataires", selection: $mode) {
                                Text("Une personne").tag("targeted")
                                Text("Plusieurs").tag("broadcast")
                            }
                            .pickerStyle(.segmented)

                            if mode == "targeted" {
                                Picker("Participant", selection: $selectedTargetId) {
                                    ForEach(targets) { participant in
                                        Text(participant.user.displayName).tag(participant.userId)
                                    }
                                }
                                .pickerStyle(.menu)
                            } else {
                                VStack(alignment: .leading, spacing: SQSpace.xs) {
                                    ForEach(targets) { participant in
                                        Toggle(
                                            participant.user.displayName,
                                            isOn: binding(for: participant.userId)
                                        )
                                        .tint(SQColor.brandRed)
                                    }
                                }
                            }
                        }

                        TextField("Message facultatif", text: $message, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: SQSpace.sm) {
                            Button {
                                create(offerShare: true)
                            } label: {
                                Label("Partager", systemImage: "dot.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SQColor.brandRed)

                            Button {
                                create(offerShare: false)
                            } label: {
                                Text("Demander")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(SQColor.brandRed)
                        }
                        .disabled(!canSubmit)
                    }
                    .padding(SQSpace.md)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1)
                    }

                    if let error = coordinator.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                    }
                }
                .padding()
            }
            .signalQuestBackground()
            .navigationTitle("Partage en direct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Label("Actif uniquement au premier plan", systemImage: "iphone.and.arrow.forward")
                .font(SQType.caption.weight(.semibold))
                .foregroundStyle(SQColor.label)
            Text("Sur iPhone, l’envoi se met en pause si tu verrouilles l’écran ou quittes SignalQuest. Il reprend au retour tant que la session n’a pas été arrêtée.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text("iOS partage la position, la technologie et l’opérateur disponibles. Apple n’expose pas les niveaux RSRP/RSRQ à l’app.")
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelTertiary)
        }
        .padding(SQSpace.md)
        .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func binding(for userId: String) -> Binding<Bool> {
        Binding(
            get: { selectedBroadcastIds.contains(userId) },
            set: { selected in
                if selected { selectedBroadcastIds.insert(userId) }
                else { selectedBroadcastIds.remove(userId) }
            }
        )
    }

    private func create(offerShare: Bool) {
        let targetId = conversation.isGroup && mode == "targeted" ? selectedTargetId : nil
        let targetIds = conversation.isGroup && mode == "broadcast"
            ? Array(selectedBroadcastIds).sorted()
            : []
        Task {
            await coordinator.create(
                conversationId: conversation.id,
                e2eeEnabled: conversation.e2eeEnabled == true,
                currentUserId: currentUserId,
                offerShare: offerShare,
                message: message,
                mode: conversation.isGroup ? mode : nil,
                targetUserId: targetId,
                targetUserIds: targetIds
            )
            if coordinator.errorMessage == nil { message = "" }
        }
    }
}

private struct LiveShareSessionCard: View {
    @ObservedObject var coordinator: ConversationLiveShareCoordinator
    let session: LiveShareSession
    let conversation: MessageConversation
    let currentUserId: String

    private var payload: LiveSharePayload? { coordinator.payload(for: session.id) }
    private var isIncomingRequest: Bool {
        session.status == "pending" && session.sharerId == currentUserId
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            content(at: timeline.date)
        }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SQType.body.weight(.semibold))
                        .foregroundStyle(SQColor.label)
                    Text(statusText(at: now))
                        .font(SQType.micro.weight(.semibold))
                        .foregroundStyle(session.status == "active"
                                         && LiveShareLocationFreshness.isCurrent(payload, at: now)
                                         ? SQColor.success : SQColor.labelSecondary)
                }
                Spacer()
                if coordinator.isBusy { ProgressView().controlSize(.small) }
            }

            if let message = session.message, !message.isEmpty {
                Text(message)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            if session.status == "active",
               LiveShareLocationFreshness.isCurrent(payload, at: now),
               let location = payload?.location {
                LiveShareMapPreview(location: location)
            } else if session.status == "active", payload?.location != nil {
                Text("Position indisponible")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else if session.status == "active" {
                Text(payload?.radio == nil
                     ? "En attente de la première position…"
                     : "GPS indisponible, données réseau reçues.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            if let radioLine {
                Label(radioLine, systemImage: "antenna.radiowaves.left.and.right")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let updated = LiveShareLocationFreshness.observedAt(payload) ?? session.lastUpdateAt,
               updated <= now {
                Text("Actualisé à \(updated.formatted(date: .omitted, time: .standard))")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            if isIncomingRequest {
                HStack(spacing: SQSpace.sm) {
                    Button("Accepter") {
                        Task { await coordinator.accept(sessionId: session.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SQColor.brandRed)
                    Button("Refuser") {
                        Task { await coordinator.decline(sessionId: session.id) }
                    }
                    .buttonStyle(.bordered)
                    .tint(SQColor.brandRed)
                }
                .disabled(coordinator.isBusy)
            } else {
                Button(role: .destructive) {
                    Task { await coordinator.stop(sessionId: session.id) }
                } label: {
                    Label(session.status == "pending" ? "Annuler la demande" : "Arrêter", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isBusy)
            }
        }
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
    }

    private func statusText(at now: Date) -> String {
        guard session.status == "active" else { return String(localized: "En attente") }
        guard payload != nil else { return String(localized: "En attente") }
        return LiveShareLocationFreshness.isCurrent(payload, at: now)
            ? String(localized: "En direct")
            : String(localized: "Position indisponible")
    }

    private var title: String {
        if session.status == "pending" {
            return isIncomingRequest
                ? String(localized: "\(name(for: session.requesterId)) demande ton partage")
                : String(localized: "Demande envoyée à \(name(for: session.sharerId))")
        }
        return session.sharerId == currentUserId
            ? String(localized: "Tu partages avec \(name(for: session.requesterId))")
            : String(localized: "\(name(for: session.sharerId)) partage avec toi")
    }

    private var radioLine: String? {
        guard let radio = payload?.radio else { return nil }
        let parts = [
            radio.displayOperatorName,
            radio.technology ?? radio.connectionType,
            radio.band.map { SQUnits.band($0, technology: radio.technology) },
            radio.rsrp.map { "RSRP \($0) dBm" },
            radio.rsrq.map { "RSRQ \($0) dB" },
            radio.snr.map { "SINR \($0) dB" }
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func name(for userId: String) -> String {
        if userId == currentUserId { return String(localized: "toi") }
        return conversation.participants.first(where: { $0.userId == userId })?.user.displayName
            ?? (userId == session.requesterId ? session.requester?.name : session.sharer?.name)
            ?? "un participant"
    }
}

private struct LiveShareMapPreview: View {
    let location: LiveShareLocation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var region: MKCoordinateRegion

    init(location: LiveShareLocation) {
        self.location = location
        _region = State(initialValue: Self.region(for: location))
    }

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: [LiveShareMapPoint(location: location)]) { point in
            MapAnnotation(coordinate: point.coordinate) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed, Color.white)
                    .shadow(radius: 3)
                    .accessibilityLabel("Position partagée")
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                .font(SQType.micro.monospacedDigit())
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, SQSpace.xs)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(SQSpace.sm)
        }
        .onChangeCompat(of: location) { _, newValue in
            withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
                region = Self.region(for: newValue)
            }
        }
    }

    private static func region(for location: LiveShareLocation) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }
}

private struct LiveShareMapPoint: Identifiable {
    let id = "live-share"
    let coordinate: CLLocationCoordinate2D

    init(location: LiveShareLocation) {
        coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
}

/// Suppression demandée depuis le menu d'un message, en attente de confirmation.
/// Action VoiceOver nommée de l'en-tête d'une conversation chiffrée : le
/// bouton « Chiffrée · texte seulement » est fondu dans l'élément combiné.
private struct EncryptionInfoAction: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: Text("Ce que protège le chiffrement"), action)
        } else {
            content
        }
    }
}

/// Bulle lue d'un seul tenant par VoiceOver quand un résumé existe ; sinon
/// ses éléments sont combinés, ou gardés séparés s'ils sont interactifs.
private struct SpokenBubble: ViewModifier {
    let summary: String?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let summary, !interactive {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: summary))
        } else {
            content.accessibilityElement(children: interactive ? .contain : .combine)
        }
    }
}

private struct PendingMessageDeletion {
    let message: MessageItem
    let forEveryone: Bool
}
