import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import CryptoKit
import CoreTransferable

struct ConversationDetailView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Message sur lequel la conversation s'ouvre (résultat de la recherche de la liste).
    var focusMessageId: String? = nil

    init(conversation: MessageConversation, service: MessagesServicing, e2ee: E2EEServicing?, focusMessageId: String? = nil) {
        self.conversation = conversation
        self.service = service
        self.e2ee = e2ee
        self.focusMessageId = focusMessageId
        // Le dernier réglage connu de cet appareil : le voile d'une conversation
        // protégée est en place dès la première image.
        _secretPolicy = State(initialValue: AppEnvironment.usesDemoData
            ? ConversationSecretPolicy()
            : ConversationSecretPolicyCache.policy(conversationId: conversation.id))
    }

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
    /// Vrai dès que le premier chargement a répondu (succès ou échec) : tant qu'il
    /// ne l'est pas, une liste vide veut dire « pas encore là », pas « vide ».
    @State private var hasLoadedOnce = false
    @State private var focusHandled = false
    @State private var olderCursor: String?
    /// Fil v2 : nombre de messages présentés (les plus récents) et existence de plus anciens.
    @State private var v2Limit = E2EEV2ThreadWindow.pageSize
    @State private var v2HasOlder = false
    @State private var isLoadingOlder = false
    @State private var readReceipts: [ReadReceipt] = []
    /// Accusés « distribué » des autres membres, et vrai dès que `/receipts` a répondu :
    /// avant, seul le « Lu » de la page v1 s'affiche, comme auparavant.
    @State private var deliveryReceipts: [DeliveryReceipt] = []
    @State private var receiptsKnown = false
    @State private var receiptsTask: Task<Void, Never>?
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
    /// Nom donné au groupe depuis ses réglages pendant cette ouverture.
    @State private var renamedTitle: String?
    /// Nombre de membres après un ajout ou un retrait depuis les réglages.
    @State private var updatedMemberCount: Int?
    @State private var confirmsLocationShare = false
    /// Vrai une fois la nature v1/v2 de la conversation établie : le bandeau
    /// du mot de passe v1 ne doit jamais apparaître, même un instant, en v2.
    @State private var v2Resolved = false
    /// Avis du fil v2 (§2.4, §4.2, §4.3, §3.2), posés en tête.
    @State private var v2Notices: [E2EEV2ThreadPresentation.Notice] = []
    @State private var v2LoadInFlight = false
    @State private var v2LoadAgain = false
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
    /// Photos et notes vocales en cours d'envoi, ou restées dans la file durable :
    /// leur bulle locale porte Renvoyer / Supprimer comme un texte non envoyé.
    @State private var pendingAttachmentSends: [String: PendingAttachmentSend] = [:]
    /// E2EE-UX-04 — vrai quand une rotation de clé (staleKey/409) a été détectée :
    /// affiche un bandeau « appuie pour resynchroniser » au lieu de bulles muettes.
    @State private var needsKeyResync = false
    @State private var isResyncingKey = false
    @State private var showReportUser = false
    @State private var showGroupSettings = false
    /// Posé par les réglages après un départ du groupe : la conversation se ferme.
    @State private var leftGroup = false
    @State private var typingUntil: Date?
    /// Qui écrit : son avatar, jamais le nôtre.
    @State private var typingUserId: String?
    @State private var lastTypingSignal: Date = .distantPast
    /// Borne du dernier sync delta — max des dates créé/édité/supprimé vues.
    @State private var lastSync: Date = .distantPast
    /// Présence « actif sur la conversation » : ids des participants regardant la conv.
    @State private var conversationViewers: [String] = []
    /// Vrai dès qu'un événement de présence a été lu : avant, l'état « en ligne »
    /// vient de la liste des conversations ; ensuite, des spectateurs en direct.
    @State private var viewersKnown = false
    @State private var activePingTask: Task<Void, Never>?
    /// Dates de lecture posées par nous, hors du cycle de rendu (type référence).
    @State private var readGate = OwnReadGate()

    // Messagerie avancée
    @State private var pinnedMessages: [PinnedMessage] = []
    /// Épinglé affiché dans la barre ; chaque toucher y mène puis passe au suivant.
    @State private var pinnedIndex = 0
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
    /// Incrémenté à chaque événement du serveur : un fil ouvert se relit (B04).
    @State private var threadRefreshToken = 0
    /// Repère « N nouveaux messages », calculé une fois à l'ouverture (M05).
    @State private var unreadDivider: UnreadDivider?
    @State private var unreadDividerComputed = false
    /// Enveloppe du dernier message reçu en v2 : de quoi accuser « distribué » depuis le fil (U05).
    @State private var v2LastIncomingEnvelopeId: String?
    @State private var showSearch = false
    @State private var showScheduled = false
    @State private var showReminders = false
    @State private var showSaved = false
    /// Médias et fichiers de la conversation (plan 3, vague 2).
    @State private var showMedia = false
    /// Messages éphémères (parité Android) : quand actif, tout ce qui part
    /// (texte, photo, note vocale, position) porte un TTL de 24 h (le backend
    /// pose `expiresAt`).
    @State private var ephemeralEnabled = false
    /// 24 h par défaut ; la durée choisie dans les réglages « protégée » quand il y en a une.
    private var ephemeralTTL: Int {
        guard ephemeralEnabled else { return 0 }
        let chosen = secretPolicy?.outgoingTTLSeconds ?? 0
        return chosen > 0 ? chosen : 86_400
    }
    @State private var isSharingLocation = false
    @State private var showLiveShare = false
    @State private var showSchedulePicker = false
    @State private var showNewPoll = false
    @State private var reminderTarget: MessageItem?
    /// Texte ouvert dans une feuille où il se sélectionne librement.
    @State private var selectableText: SelectableText?
    /// Message auquel on réagit avec un emoji hors de la palette rapide.
    @State private var emojiPickerTarget: MessageItem?
    /// Texte à transférer vers une autre conversation.
    @State private var forwardTarget: ForwardPayload?
    /// Photos, vidéos et fichiers en attente dans le compositeur (partage reçu,
    /// glisser-déposer, coller) : ils partent par les envois habituels, le texte
    /// tapé en légende de la première.
    @State private var stagedAttachments: [StagedAttachment] = []

    // Photos en grand + publications partagées interactives (parité Android).
    /// Photo de la conversation ouverte en plein écran (tap sur l'image).
    @State private var imageViewer: ImageViewerSession?
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

    // Appels dans le fil : insérés par date parmi les messages (lecture seule).
    @State private var callEvents: [CallThreadEvent] = []
    @State private var callsNextBefore: String?
    @State private var callsExhausted = false
    @State private var callsFetchedOnce = false
    /// Route absente ou refusée : aucun appel n'est affiché, sans erreur.
    @State private var callsUnavailable = false
    @State private var callsLoading = false
    @State private var lastCallRefresh: Date = .distantPast

    // Conversation protégée : Face ID, voile, alerte de capture, suppression automatique.
    @State private var secretPolicy: ConversationSecretPolicy?
    @State private var protectionUnlocked = false
    @State private var isAuthenticating = false
    @State private var isScreenCaptured = false
    @State private var policyFetchGaveUp = false
    @State private var ephemeralDefaultApplied = false
    @State private var showProtection = false
    /// Posé quand la conversation s'affiche à côté de la liste (iPad) : pas de retour.
    @Environment(\.sqMessagesCloseDetail) private var closeSplitDetail
    private var inSplitDetail: Bool { closeSplitDetail != nil }

    /// Quitte la conversation : retour en arrière sur iPhone, sélection levée à côté de la liste (iPad).
    private func closeConversation() {
        if let closeSplitDetail { closeSplitDetail() } else { dismiss() }
    }

    private var isE2EE: Bool { conversation.e2eeEnabled == true }
    private var canSend: Bool {
        EncryptedConversationSurfaces.canSend(isEncrypted: isE2EE, usesV2: usesV2, legacyUnlocked: isE2EEUnlocked)
    }
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

    /// Le corps est coupé en deux : la chaîne de modificateurs entière dépassait ce que le
    /// compilateur type-check en un temps raisonnable.
    private var conversationBase: some View {
        VStack(spacing: 0) {
            topBar

            if !networkPath.isOnline {
                MessagesOfflineBanner()
            }

            if EncryptedConversationSurfaces.showsLegacyUnlockBanner(
                isEncrypted: isE2EE, v2Resolved: v2Resolved, isV2: conversationIsV2, legacyUnlocked: isE2EEUnlocked
            ) {
                // Carte au-dessus des messages : bouclier, une phrase, et le
                // bouton qui ouvre la feuille de déverrouillage.
                VStack(spacing: SQSpace.sm) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(SQColor.success)
                        .frame(width: 44, height: 44)
                        .background(SQColor.successSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Conversation chiffrée")
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.label)
                    Text("Déverrouille le chiffrement pour lire et écrire. Tes messages restent illisibles en dehors de tes appareils.")
                        .font(SQType.subhead(.regular))
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    GradientButton("Déverrouiller", systemImage: "lock.open") { showUnlockSheet = true }
                        .fixedSize()
                        .accessibilityIdentifier("conversation.unlock")
                }
                .frame(maxWidth: .infinity)
                .padding(SQSpace.lg)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .padding(.horizontal, SQSpace.md)
                .padding(.top, SQSpace.sm)
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
                    .font(SQType.subhead(.semibold))
                    .padding(SQSpace.md)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .foregroundStyle(SQColor.label)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, SQSpace.md)
                .padding(.top, SQSpace.sm)
                .disabled(isResyncingKey)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            pinnedBar

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
                        if olderCursor != nil || v2HasOlder {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { Task { await loadOlder() } }
                        }
                        if isLoadingOlder {
                            SQSpinner()
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
                        if messages.isEmpty, !v2Unavailable {
                            if !hasLoadedOnce {
                                if errorMessage == nil {
                                    SQSpinner()
                                        .tint(SQColor.brandRed)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, SQSpace.xl)
                                }
                            } else if errorMessage == nil, v2Notices.isEmpty {
                                EmptyStateView(
                                    title: "Aucun message pour l’instant",
                                    message: "Les messages de cette conversation apparaîtront ici.",
                                    systemImage: "bubble.left.and.bubble.right"
                                )
                                .accessibilityIdentifier("conversation.empty")
                            }
                        }
                        // PERF-MSG-04 — Itère directement sur `messages` (identité
                        // stable `\.id`, comme l'ancien `id: \.element.id`) au lieu
                        // de `Array(messages.enumerated())`, qui matérialisait un
                        // tableau de tuples à CHAQUE évaluation du body (frappe,
                        // sendStatus, surbrillance…). L'index — nécessaire à l'accès
                        // aux voisins — vient d'une table O(1) mémoïsée, reconstruite
                        // seulement quand la structure de la liste change.
                        // Le pied « Lu / Vu par » suit MON dernier message, pas le bas de la liste.
                        let receiptMessageId = messages.last { $0.senderId == currentUserId && !$0.id.hasPrefix("local-") }?.id
                        // Appels placés par date : devant le premier message plus récent, ou à la suite.
                        let callPlacement = CallThreadPlacement.make(messages: messages, events: callsUnavailable ? [] : callEvents)
                        ForEach(messages) { message in
                            let index = renderCache.index(of: message, in: messages)
                            let previous = index > 0 ? messages[index - 1] : nil
                            let next = index + 1 < messages.count ? messages[index + 1] : nil
                            let stamp = sectionStamp(for: message, previous: previous)
                            let callsBefore = callPlacement.before[message.id] ?? []
                            let nextHasCalls = next.map { callPlacement.before[$0.id]?.isEmpty == false } ?? false
                            VStack(spacing: 0) {
                                ForEach(callsBefore) { event in
                                    callRow(event)
                                }
                                if let stamp {
                                    Text(stamp)
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.chipInk)
                                        .padding(.horizontal, SQSpace.sm2)
                                        .padding(.vertical, 4)
                                        .background(SQColor.chip, in: Capsule(style: .continuous))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, SQSpace.sm)
                                        .accessibilityIdentifier("conversation.stamp")
                                }
                                if let unreadDivider, unreadDivider.messageId == message.id {
                                    unreadDividerRow(unreadDivider)
                                }
                                messageBubble(
                                    message,
                                    isGroupStart: stamp != nil || previous == nil || previous?.senderId != message.senderId
                                        || unreadDivider?.messageId == message.id || !callsBefore.isEmpty,
                                    isGroupEnd: isGroupEnd(message, next: next) || nextHasCalls
                                )
                                if message.id == receiptMessageId {
                                    readReceiptFooter(for: message)
                                }
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
                        ForEach(callPlacement.trailing) { event in
                            callRow(event)
                        }
                        // Frappe : dernier élément de la liste, pour qu'elle pousse le contenu
                        // au lieu de rétrécir la zone visible (parité Android).
                        typingIndicator
                            .id(Self.typingRowId)
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
                .onChangeCompat(of: messages.last?.id) { old, _ in
                    guard let last = messages.last else { return }
                    let mine = last.id.hasPrefix("local-") || last.senderId == currentUserId
                    if isNearBottom || mine {
                        // Ouverture (rien avant) ou bulle locale remplacée par la réponse
                        // serveur : se placer sans glisser depuis le haut de la liste.
                        let replacesLocal = old?.hasPrefix("local-") == true && !last.id.hasPrefix("local-")
                        if old == nil || replacesLocal {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                // Beaucoup de nouveautés : l'ouverture se place sur le repère, pas en bas.
                                if old == nil, let divider = unreadDivider, divider.count >= UnreadDivider.scrollsToDividerFrom {
                                    proxy.scrollTo(divider.messageId, anchor: .top)
                                } else {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        } else {
                            withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    } else {
                        hasUnseenMessages = true
                    }
                }
                // Un appel qui se termine ajoute une ligne en bas : on y reste si on y était.
                .onChangeCompat(of: callEvents.first?.callId) { _, _ in
                    guard isNearBottom, let last = messages.last, let newest = callEvents.first,
                          let lastDate = last.createdAt, newest.startedAt > lastDate else { return }
                    withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(Self.typingRowId, anchor: .bottom) }
                }
                // La frappe ou le « Lu » ajoutent une ligne en bas : on y reste si on y était.
                .onChangeCompat(of: typingUntil != nil) { _, visible in
                    guard visible, isNearBottom else { return }
                    withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(Self.typingRowId, anchor: .bottom) }
                }
                .onChangeCompat(of: receiptFooterKey) { _, key in
                    guard key != nil, isNearBottom, let last = messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                // Le clavier réduit la zone visible : on reste collé au dernier message si on y était.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    guard isNearBottom, let last = messages.last else { return }
                    withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottom) {
                    if hasUnseenMessages {
                        Button {
                            Haptics.selection()
                            hasUnseenMessages = false
                            if let last = messages.last { withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                        } label: {
                            Label("Nouveaux messages", systemImage: "arrow.down")
                                .font(SQType.subhead(.semibold))
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
                    ? messages.compactMap { message in
                        (isReadableV2(message) ? message.content : decryptedMessages[message.id])
                            .map { (message: message, text: $0) }
                    }
                    : nil,
                subtitle: conversationTitle
            ) { messageId in
                handleSearchSelection(messageId)
            }
        }
        .navigationDestination(isPresented: $showMedia) {
            ConversationMediaView(conversation: conversation, service: service, subtitle: conversationTitle)
        }
        .navigationDestination(isPresented: $showScheduled) {
            ScheduledMessagesView(conversation: conversation, service: service, e2ee: e2ee, subtitle: conversationTitle)
        }
        .navigationDestination(isPresented: $showReminders) {
            RemindersView(conversation: conversation, service: service, e2ee: e2ee, subtitle: conversationTitle)
        }
        .sheet(item: $threadTarget) { target in
            ThreadView(parentMessage: target, conversation: conversation, service: service, e2ee: e2ee,
                       refreshToken: threadRefreshToken)
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
        .confirmationDialog(
            "Envoyer ta position ?",
            isPresented: $confirmsLocationShare,
            titleVisibility: .visible
        ) {
            Button("Envoyer ma position") { Task { await sendCurrentLocation() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ta position exacte et l’adresse la plus proche seront envoyées dans \(conversationTitle).")
        }
        .sheet(isPresented: $showSchedulePicker) {
            ScheduleMessageSheet(
                conversation: conversation,
                service: service,
                e2ee: e2ee,
                initialText: scheduleSeedText,
                subtitle: conversation.isGroup ? sheetSubtitle : String(localized: "À \(conversationTitle)")
            ) {
                Haptics.success()
                // Le texte programmé restait dans le champ et le brouillon : un appui
                // sur Envoyer le doublait aussitôt (AF-MSG-12).
                clearComposer()
                draftAutosaver?.discard()
                scheduleSeedText = ""
                inAppNotifications.show(SQInAppNotificationItem(
                    body: String(localized: "Message programmé."),
                    variant: .success
                ))
            }
        }
        .sheet(isPresented: $showNewPoll) {
            NewPollView(conversation: conversation, service: service, e2ee: e2ee, subtitle: sheetSubtitle) { message, poll in
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
                    currentUserId: currentUserId,
                    subtitle: String(localized: "Ta position et ton réseau, en continu, dans \(conversationTitle).")
                )
            }
        }
        .sheet(item: $emojiPickerTarget) { target in
            EmojiReactionSheet(
                chosen: Set(target.reactions.filter { $0.userId == currentUserId }.map(\.emoji))
            ) { emoji in
                Task { await toggleReaction(message: target, emoji: emoji) }
            }
        }
        .sheet(item: $forwardTarget) { payload in
            ForwardMessageSheet(
                text: payload.text,
                sourceIsEncrypted: payload.sourceIsEncrypted,
                service: service,
                e2ee: e2ee,
                currentUserId: currentUserId,
                excludedConversationId: conversation.id
            ) {
                Haptics.success()
                inAppNotifications.show(SQInAppNotificationItem(
                    body: String(localized: "Message transféré."),
                    variant: .success
                ))
            }
        }
        .sheet(item: $selectableText) { item in
            SelectableTextSheet(text: item.text)
        }
        .sheet(item: $reminderTarget) { target in
            AddReminderSheet(conversation: conversation, message: target, service: service, subtitle: sheetSubtitle) {
                Haptics.success()
            }
        }
        .sheet(isPresented: $showReportUser) {
            if let id = otherParticipantId {
                ReportSheet(target: .profile(id), service: services.reports)
            }
        }
        .sheet(item: $safetyNumberPeer, onDismiss: { Task { await loadV2() } }) { peer in
            NavigationStack {
                Group {
                    if let access = services.e2eeV2Messaging.safetyNumberAccess() {
                        E2EEV2SafetyNumberView(
                            peerUserId: peer.userId,
                            peerName: peer.name ?? String(localized: "Ce membre"),
                            ownUserId: access.ownUserId,
                            ownAccountKey: access.ownAccountKey,
                            trust: access.trust,
                            onClose: { safetyNumberPeer = nil }
                        )
                    } else {
                        // Sans accès aux clés, la feuille dit pourquoi elle est vide.
                        Text("Le numéro de sécurité n’est pas disponible pour le moment.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                            .multilineTextAlignment(.center)
                            .padding(SQSpace.lg)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .signalQuestBackground()
                            .navigationTitle(Text("Numéro de sécurité"))
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fermer") { safetyNumberPeer = nil }
                    }
                }
            }
        }
        .sheet(item: $reportTarget) { message in
            ReportSheet(
                reasons: usesV2 ? E2EEV2MessageReport.reasons : ReportReason.messageReasons,
                notice: usesV2
                    ? E2EEV2MessageReport.notice
                    : isE2EE
                    ? String(localized: "Conversation chiffrée : si l’équipe de modération dispose d’une clé de vérification, la clé de cette conversation lui est transmise, chiffrée pour elle seule. Elle pourra alors en lire les messages.")
                    : nil,
                // §11, D.10 : le rapport v2 ne porte que son motif en clair.
                allowsComment: !usesV2
            ) { reason, comment in
                try await report(message, reason: reason, comment: comment)
            }
        }
    }

    var body: some View {
        conversationBase
        .modifier(ConversationInputModifier(
            acceptsDrops: canSend && editTarget == nil && !showsProtectionVeil,
            pendingShareId: router.pendingShare?.id,
            onProviders: { providers in Task { await importProviders(providers) } },
            onPendingShare: { await consumePendingShare() }
        ))
        .accessibilityHidden(showsProtectionVeil)
        .overlay {
            if showsProtectionVeil { protectionVeil }
        }
        .sheet(isPresented: $showProtection) {
            ProtectedConversationSheet(
                conversationId: conversation.id,
                subtitle: sheetSubtitle,
                service: service,
                initial: secretPolicy ?? ConversationSecretPolicy()
            ) { updated, authenticated in
                applySecretPolicy(updated)
                if authenticated { protectionUnlocked = true }
            }
        }
        .sheet(isPresented: $showGroupSettings, onDismiss: { if leftGroup { closeConversation() } }) {
            GroupSettingsView(conversation: conversation, service: service, e2ee: e2ee,
                              onRenamed: { renamedTitle = $0 },
                              onMembersChanged: { updatedMemberCount = $0 }) {
                // Groupe quitté : rester sur la conversation n'aurait plus de sens.
                leftGroup = true
            }
        }
        .sheet(isPresented: $showSaved) {
            SavedMessagesView(
                service: service, currentUserId: currentUserId, e2ee: e2ee, currentConversationId: conversation.id,
                onSelectMessage: { handleSearchSelection($0) }
            )
        }
        // Photo de la conversation en plein écran (zoom + glisser pour fermer).
        .fullScreenCover(item: $imageViewer) { session in
            MessageImageViewer(targets: session.targets, initialIndex: session.initialIndex)
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
            if EncryptedConversationSurfaces.hidesSnapshot(of: conversation)
                || secretPolicy?.requireBiometric == true || secretPolicy?.blockScreenshots == true {
                AppSensitiveContentMarker()
            }
        }
        // Clavier de l'iPad : ⌘F cherche dans la conversation, Échap ferme (citation, modification, puis l'écran).
        .background { keyboardShortcutButtons }
        // Les notes vocales se suivent : le lecteur connaît celles du fil ouvert (M15).
        .onChangeCompat(of: messages.count) { _, _ in registerVoiceSequence() }
        .onChangeCompat(of: messages.last?.id) { _, _ in registerVoiceSequence() }
        .onAppear {
            // Le dock flottant global est masqué le temps de la conversation.
            router.isDockHidden = true
            isOnScreen = true
        }
        // Rappel depuis les Récents de Téléphone : mêmes contrôles qu'un appui
        // sur le bouton d'appel.
        .task(id: hasLoadedOnce) {
            guard hasLoadedOnce, !focusHandled, let target = focusMessageId else { return }
            focusHandled = true
            // Laisse le défilement initial vers le bas se terminer avant d'aller au message.
            try? await Task.sleep(for: .milliseconds(350))
            handleSearchSelection(target)
        }
        // Historique d'appels une fois le premier chargement répondu.
        .task(id: hasLoadedOnce) {
            guard hasLoadedOnce else { return }
            await syncCallHistory()
        }
        .task(id: conversation.id) { await refreshSecretPolicy() }
        // Face ID à l'ouverture, et au retour au premier plan.
        .task(id: shouldPromptUnlock) {
            guard shouldPromptUnlock else { return }
            await unlockProtection()
        }
        .onAppear { isScreenCaptured = ScreenCaptureState.isCaptured }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isScreenCaptured = ScreenCaptureState.isCaptured
        }
        // Capture d'écran faite sur cet appareil : bannière dans la conversation.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard isOnScreen, secretPolicy?.blockScreenshots == true, !holdsProtection else { return }
            inAppNotifications.show(SQInAppNotificationItem(
                body: String(localized: "Capture d’écran détectée dans cette conversation."),
                variant: .warning,
                duration: .seconds(5)
            ))
        }
        .task(id: router.pendingCall) {
            guard let pending = router.pendingCall, pending.conversationId == conversation.id else { return }
            router.pendingCall = nil
            guard pending.isFresh, SQFeatures.callsEnabled else { return }
            startCall(mode: pending.video ? "video" : "audio")
        }
        .task {
            conversationIsV2 = EncryptedConversationSurfaces.isV2(conversation)
            // §14.2 : une conversation chiffrée v1 passe en v2 à son ouverture,
            // si tous ses membres lisent le v2 (règle commune, v0.4.17).
            if !conversationIsV2, conversation.e2eeEnabled == true,
               await services.e2eeV2Messaging.migrateIfReady(conversation) {
                conversationIsV2 = true
            }
            v2Resolved = true
            await restoreDraftIfNeeded()
            if usesV2 {
                await loadV2()
                guard !Task.isCancelled else { return }
                await refreshReceipts()
                await markRead()
                // Relève en direct (événements du serveur, relevé périodique) et
                // présence à l'écran, comme en v1 : le serveur ne pousse rien à
                // l'appareil qui regarde la conversation (A7).
                guard !Task.isCancelled, isOnScreen else { return }
                startSync()
                startActivePing()
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
        .onReceive(NotificationCenter.default.publisher(for: PushNotificationService.e2eeV2EnvelopeReceived)) { _ in
            guard usesV2, isOnScreen else { return }
            Task {
                await loadV2()
                await markRead()
            }
        }
        .onDisappear {
            isOnScreen = false
            router.isDockHidden = false
            VoiceNotePlayer.shared.sequence = []
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
                Task {
                    if usesV2 { await loadV2() } else { await refreshDelta() }
                    await markReadIfLastIncoming()
                }
            } else {
                stopSync()
                stopActivePing(sendLeave: true)
                if let draftAutosaver { Task { await draftAutosaver.flush() } }
                if phase == .background, secretPolicy?.requireBiometric == true {
                    protectionUnlocked = false
                    dismissContentPresentations()
                }
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
    /// Barre du haut Halo : retour rond, avatar et nom avec le statut, puis
    /// Appeler et ⋯ en boutons ronds, sur le fond de page avec un filet.
    private var topBar: some View {
        HStack(spacing: SQSpace.sm2) {
            if !inSplitDetail {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "conversation.back") { dismiss() }
            }

            // Avatar, nom et statut forment un seul élément VoiceOver : seule,
            // l'initiale masquée de l'avatar restait un texte non exposé. En
            // conversation chiffrée, l'explication reste dans le menu ⋯ et en
            // action VoiceOver.
            HStack(spacing: SQSpace.sm2) {
                ConversationAvatar(conversation: conversation, currentUserId: currentUserId, size: 38)
                    .overlay(alignment: .bottomTrailing) {
                        if otherIsOnline {
                            Circle()
                                .fill(SQColor.brandGreen)
                                .frame(width: 12, height: 12)
                                .overlay { Circle().stroke(SQColor.bg, lineWidth: 2.5) }
                                .offset(x: 2, y: 2)
                        }
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        // Deux lignes, puis réduction : en très grand texte, le nom
                        // était coupé.
                        Text(conversationTitle)
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .accessibilityIdentifier("conversation.title")
                        SQUserBadges(
                            badges: conversation.otherParticipantBadges(excluding: currentUserId),
                            size: 12
                        )
                    }
                    if otherIsOnline || conversation.isGroup || otherLastSeenLabel != nil {
                        if otherIsOnline {
                            Text("en ligne")
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.success)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .accessibilityIdentifier("conversation.status")
                        } else if !conversation.isGroup, let lastSeen = otherLastSeenLabel {
                            Text(verbatim: lastSeen)
                                .font(SQType.micro(.regular))
                                .foregroundStyle(SQColor.labelSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .accessibilityIdentifier("conversation.lastSeen")
                        } else {
                            Text("\(updatedMemberCount ?? conversation.participants.count) membres")
                                .font(SQType.micro(.regular))
                                .foregroundStyle(SQColor.labelSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .accessibilityIdentifier("conversation.members")
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(networkPath.isOnline ? SQColor.label : SQColor.labelTertiary)
                        .frame(width: 44, height: 44)
                        .sqSurface(SQColor.chip, in: Circle())
                        .contentShape(Circle())
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
                // En v2, ces écrans passent par des routes qui ne connaissent pas les messages
                // chiffrés : ils s'ouvriraient vides (U03).
                if !conversationIsV2 {
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
                }
                if isE2EE {
                    Button { showEncryptionInfo = true } label: {
                        Label("Chiffrement", systemImage: "lock")
                    }
                    .accessibilityIdentifier("conversation.encryption.info")
                }
                Button { showProtection = true } label: {
                    Label("Conversation protégée", systemImage: "lock.shield")
                }
                .accessibilityIdentifier("conversation.protection")
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Plus d’options")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm)
        .background {
            SQColor.bg
                .overlay(alignment: .bottom) { Rectangle().fill(SQColor.separator).frame(height: 1) }
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Avatar de l'autre participant (1:1) pour la barre haute.
    private var typingParticipant: ConversationParticipant? {
        guard let typingUserId else { return nil }
        return conversation.participants.first { $0.userId == typingUserId }
    }

    /// Prénom de celui qui écrit, pour « Léa écrit… » en groupe.
    private var typingFirstName: String? {
        guard let name = typingParticipant?.user.displayName,
              let first = name.split(separator: " ").first.map(String.init), !first.isEmpty else { return nil }
        return first
    }

    private var otherParticipantAvatarURL: URL? {
        guard !conversation.isGroup else { return nil }
        // Sans repli sur le premier participant : ce peut être nous.
        return conversation.participants.first { $0.userId != currentUserId }?.user.avatarUrl
    }

    /// Présence : l'autre participant (1:1) est en ligne. `conversation` est figée
    /// à l'ouverture ; une fois la présence en direct connue, elle prend le relais.
    private var otherIsOnline: Bool {
        guard !conversation.isGroup else { return false }
        if viewersKnown { return otherIsViewing }
        return conversation.participants.contains { $0.userId != currentUserId && $0.presence?.isOnline == true }
    }

    /// « vu à 14:32 », « vu hier à 14:32 » ou « vu le 12 oct. » (1:1). Le serveur
    /// ne donne `lastSeenAt` que si l'autre l'autorise : nil, rien n'est affiché.
    private var otherLastSeenLabel: String? {
        guard !conversation.isGroup,
              let date = conversation.participants
                .first(where: { $0.userId != currentUserId })?.presence?.lastSeenAt,
              date <= Date().addingTimeInterval(60)
        else { return nil }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "vu à \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "vu hier à \(time)") }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return String(localized: "vu le \(day)")
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
                    Text(ephemeralTTL == 86_400
                         ? String(localized: "Messages éphémères · disparaissent après 24 h")
                         : String(localized: "Messages éphémères · disparaissent après \(ProtectedConversationSheet.durationLabel(ephemeralTTL))"))
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.accentInk)
                    Spacer(minLength: SQSpace.sm)
                    Button { ephemeralEnabled = false } label: {
                        Text("Désactiver")
                            .font(SQType.micro.weight(.semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(SQColor.brandRed)
                .padding(.horizontal)
                .padding(.top, SQSpace.sm)
                .transition(.opacity)
            }
            if !stagedAttachments.isEmpty, editTarget == nil {
                StagedAttachmentsTray(items: stagedAttachments) { id in
                    withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) {
                        stagedAttachments.removeAll { $0.id == id }
                    }
                }
            }
            MessageComposerBar(
                canSend: canSend,
                isSending: isSending,
                isSharingLocation: isSharingLocation,
                isE2EE: isE2EE,
                canSchedule: EncryptedConversationSurfaces.allowsScheduling(isV2: conversationIsV2),
                isEditing: editTarget != nil,
                hasStagedAttachments: !stagedAttachments.isEmpty && editTarget == nil,
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
                // Coordonnées précises et adresse : un mauvais choix dans le menu
                // suffisait à les envoyer (AF-MSG-09).
                onShareLocation: { confirmsLocationShare = true },
                onLiveShare: { showLiveShare = true },
                onPickPhotos: { items, caption in Task { await sendPhotos(items, caption: caption) } },
                onPickFile: { url, caption in Task { await sendFile(at: url, caption: caption) } },
                onFilesUnavailable: { showFilesUnavailable() },
                onPaste: { Task { await pasteFromClipboard() } },
                onEditLast: { beginEditOfLastOwnMessage() },
                onCapturePhoto: { data, caption in Task { await sendCapturedPhoto(data, caption: caption) } },
                onVoiceNote: { url, duration in Task { await sendVoiceNote(url: url, duration: duration) } },
                mentionSuggestions: mentionSuggestionProvider
            )
        }
        .background {
            SQColor.bg
                .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// « N nouveaux messages » au-dessus du premier message reçu depuis la dernière lecture (M05).
    @ViewBuilder
    private func unreadDividerRow(_ divider: UnreadDivider) -> some View {
        HStack(spacing: SQSpace.sm) {
            Rectangle().fill(SQColor.accentInk.opacity(0.35)).frame(height: 1)
            if divider.count == 1 {
                Text("1 nouveau message")
                    .font(SQType.micro.weight(.semibold))
                    .foregroundStyle(SQColor.accentInk)
            } else {
                Text("\(divider.count) nouveaux messages")
                    .font(SQType.micro.weight(.semibold))
                    .foregroundStyle(SQColor.accentInk)
            }
            Rectangle().fill(SQColor.accentInk.opacity(0.35)).frame(height: 1)
        }
        .padding(.vertical, SQSpace.sm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("conversation.unreadDivider")
    }

    /// Boutons invisibles qui portent les raccourcis du clavier de l'iPad. Le raccourci ⌘N
    /// (nouveau message) est global et déjà en place.
    private var keyboardShortcutButtons: some View {
        ZStack {
            Button("") { showSearch = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { handleEscape() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Échap : ferme d'abord la citation ou la modification en cours, puis la conversation.
    private func handleEscape() {
        if editTarget != nil {
            editTarget = nil
            restoreComposerAfterEdit()
        } else if replyTarget != nil {
            replyTarget = nil
        } else {
            closeConversation()
        }
    }

    /// ↑ dans un champ vide : modifie le dernier message envoyé (texte seulement).
    private func beginEditOfLastOwnMessage() {
        guard let currentUserId, editTarget == nil,
              let last = messages.last(where: { $0.senderId == currentUserId && textOnlyContent(for: $0) != nil }),
              let text = textOnlyContent(for: last) else { return }
        replyTarget = nil
        editTarget = last
        seedComposer(text)
    }

    /// Les notes vocales du fil, dans l'ordre, pour enchaîner la suivante (M15).
    private func registerVoiceSequence() {
        guard let currentUserId else { return }
        var items: [VoiceNotePlayer.SequenceItem] = []
        var previousWasVoice = false
        for message in messages {
            if let attachment = message.attachments.first(where: { isAudioAttachment($0) && $0.url != nil }),
               let url = attachment.url, let key = attachment.id {
                items.append(.init(
                    key: key, remoteURL: url,
                    incoming: message.senderId != currentUserId, followsPrevious: previousWasVoice
                ))
                previousWasVoice = true
            } else {
                previousWasVoice = false
            }
        }
        VoiceNotePlayer.shared.sequence = items
    }

    /// Texte seul d'un message envoyé ou reçu (ni carte, ni position, ni sondage, ni pièce jointe),
    /// lisible par cet appareil. `nil` pour tout le reste, y compris le cadenas d'un message
    /// chiffré pas encore déchiffré.
    private func textOnlyContent(for message: MessageItem) -> String? {
        guard message.deletedAt == nil, !message.id.hasPrefix("local-"),
              message.attachments.isEmpty,
              shareCard(for: message) == nil,
              location(for: message) == nil,
              pollsByMessageId[message.id] == nil else { return nil }
        if message.isEncrypted && !isReadableV2(message) && decryptedMessages[message.id] == nil { return nil }
        let text = displayedContent(for: message)
        return text.isEmpty ? nil : text
    }

    /// Fichiers et vidéos : pas encore dans une conversation chiffrée (la route des pièces jointes ne les chiffre pas).
    private func showFilesUnavailable() {
        showActionError(String(localized: "Les fichiers et les vidéos ne sont pas encore disponibles dans une conversation chiffrée : seul le texte l’est."))
        Haptics.error()
    }

    /// Clé « Répondre à %@ » : le titre construit en `String` cherchait
    /// « Répondre à Alice » dans le catalogue et restait en français.
    private func replyTitle(for message: MessageItem) -> LocalizedStringKey {
        if let name = message.sender?.displayName { return "Répondre à \(name)" }
        return "Répondre au message"
    }

    /// Citation au-dessus du champ (réponse ou modification) : carte avec un
    /// liseré carmin et une croix ronde.
    private func quoteBar(title: LocalizedStringKey, text: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: SQSpace.sm2) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SQColor.brandRed)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.accentInk)
                Text(text)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .sqSingleLine()
            }
            Spacer(minLength: SQSpace.sm)
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 28, height: 28)
                    .background(SQColor.chip, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fermer")
        }
        .padding(.leading, SQSpace.sm2)
        .padding(.vertical, 2)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .padding(.horizontal, SQSpace.md)
        .padding(.top, SQSpace.sm)
    }

    // MARK: Bulles

    private func messageBubble(_ message: MessageItem, isGroupStart: Bool = true, isGroupEnd: Bool = true) -> some View {
        let mine = (message.senderId == currentUserId)
        let reactions = reactionSummaries(for: message)
        let photoOnly = isPhotoOnlyMessage(message)
        return HStack(alignment: .bottom, spacing: SQSpace.sm) {
            if mine { Spacer(minLength: 72) }
            // Avatar de l'expéditeur : uniquement sur le DERNIER message d'une
            // série entrante ; les autres bulles réservent la largeur pour
            // l'alignement.
            if !mine {
                if isGroupEnd {
                    SQAvatar(url: message.sender?.avatarUrl, name: message.sender?.displayName ?? "?", size: 26)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: 26, height: 1)
                }
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: SQSpace.xs) {
                bubbleBody(for: message, mine: mine, isGroupStart: isGroupStart, isGroupEnd: isGroupEnd, photoOnly: photoOnly, reactions: reactions)
                if sendStatus[message.id] == .failed {
                    failedRetryRow(for: message)
                }
                threadReplyBadge(for: message)
            }
            if !mine { Spacer(minLength: 72) }
        }
        // Glisser la rangée vers la droite répond au message (seulement s'il existe côté serveur).
        .modifier(SwipeToReply(isEnabled: !message.id.hasPrefix("local-") && message.deletedAt == nil) {
            beginReply(to: message)
        })
    }

    /// Corps de bulle : contenu classique (texte/carte/sondage/fichier), photo
    /// seule (la photo EST la bulle) ou publication partagée seule (la carte
    /// EST la bulle — pas de cadre brique/surface autour), avec les réactions
    /// posées en capsules qui chevauchent légèrement le bas de la bulle.
    @ViewBuilder
    private func bubbleBody(for message: MessageItem, mine: Bool, isGroupStart: Bool, isGroupEnd: Bool, photoOnly: Bool, reactions: [MessageReactionSummary]) -> some View {
        Group {
            // L'ombre reste sur la photo et la carte seules ; une bulle de texte n'en a plus
            // (un calque d'ombre par bulle coûtait cher au défilement).
            if photoOnly {
                attachmentsView(for: message, mine: mine, standalone: true)
                    .sqShadowSoft()
            } else if let embed = sharedPostEmbedTarget(for: message) {
                standaloneSharedPostEmbed(message: message, card: embed.card, postId: embed.postId, mine: mine, isGroupStart: isGroupStart)
                    .sqShadowSoft()
            } else {
                classicBubble(for: message, mine: mine, isGroupStart: isGroupStart, isGroupEnd: isGroupEnd)
            }
        }
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
            .font(SQType.micro(.regular))
            .foregroundStyle(SQColor.labelSecondary)
            .accessibilityIdentifier("message.time")
        }
    }

    private func classicBubble(for message: MessageItem, mine: Bool, isGroupStart: Bool, isGroupEnd: Bool) -> some View {
            let card = shareCard(for: message)
            let site = siteShare(for: message, hasCard: card != nil)
            // Contenu interactif dans la bulle (embed de publication, photo
            // tappable) : on garde les éléments d'accessibilité séparés
            // (.contain) pour que VoiceOver atteigne les boutons ; sinon la
            // bulle reste UN élément combiné, comme avant.
            let hasInteractiveContent =
                (card?.socialPostId != nil && !AppEnvironment.usesDemoData)
                || message.attachments.contains { $0.url != nil && isImageAttachment($0) }
                // Aperçu d'un lien : VoiceOver doit pouvoir l'ouvrir.
                || (!isE2EE && message.deletedAt == nil && displayedContent(for: message).contains("http"))
                // Citation de repli « Message d’origine » : un bouton.
                || (message.replyToId != nil && message.deletedAt == nil && quotedMessage(for: message) == nil)
                // Site partagé : la carte entière est un bouton, qui porte son propre libellé.
                || site != nil
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
                        HStack(spacing: SQSpace.xs2) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                // 0,6 donnait 2,82:1 : sous le seuil de 3:1 que
                                // WCAG 1.4.11 impose aux objets graphiques.
                                .fill(mine ? SQColor.onInk.opacity(0.7) : SQColor.brandRed)
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(quoted.sender?.displayName ?? String(localized: "Message"))
                                    .font(SQType.micro)
                                Text(displayedContent(for: quoted))
                                    .font(SQType.caption)
                                    .lineLimit(2)
                            }
                        }
                        .opacity(0.75)
                        .padding(SQSpace.xs2)
                        .background((mine ? SQColor.onInk.opacity(0.14) : SQColor.surfaceMuted.opacity(0.6)), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if let replyToId = message.replyToId, message.deletedAt == nil {
                    // Message d'origine plus ancien que les pages chargées : la citation
                    // charge l'historique jusqu'à lui au toucher.
                    Button {
                        Haptics.selection()
                        handleSearchSelection(replyToId)
                    } label: {
                        HStack(spacing: SQSpace.xs2) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(mine ? SQColor.onInk.opacity(0.7) : SQColor.brandRed)
                                .frame(width: 3)
                            Text("Message d’origine")
                                .font(SQType.micro)
                        }
                        .opacity(0.75)
                        .padding(SQSpace.xs2)
                        .frame(minHeight: 44)
                        .background((mine ? SQColor.onInk.opacity(0.14) : SQColor.surfaceMuted.opacity(0.6)), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Charge le message d’origine")
                }
                attachmentsView(for: message, mine: mine)
                if let pendingAttachment = pendingAttachmentSends[message.id] {
                    pendingAttachmentRow(pendingAttachment, mine: mine, localId: message.id)
                }
                if message.deletedAt != nil {
                    Text("Message supprimé")
                        .font(SQType.caption.italic())
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
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
                } else if let site {
                    // Site partagé en texte (P2-47), clair ou déchiffré : le texte brut
                    // reste copiable par le menu contextuel.
                    SiteShareCardBubble(card: site, mine: mine) { siteId, market in
                        router.route(toSite: siteId, market: market)
                    }
                } else {
                    let text = displayedContent(for: message)
                    if !text.isEmpty {
                        bubbleText(text, id: message.id, mine: mine)
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
                            .font(SQType.micro(.regular))
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                            .accessibilityIdentifier("message.time")
                    }
                    if message.expiresAt != nil && message.deletedAt == nil {
                        Image(systemName: "timer")
                            .font(.system(size: 11))
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                            .accessibilityLabel("Message éphémère")
                    }
                    if message.editedAt != nil && message.deletedAt == nil {
                        Text("modifié")
                            .font(SQType.micro(.regular))
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                            .accessibilityIdentifier("message.time.edited")
                    }
                    sendStatusIndicator(for: message)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .background(mine ? SQColor.label : SQColor.surface, in: bubbleShape(mine: mine, first: isGroupStart, last: isGroupEnd))
            // En OLED, bulle reçue et fond sont noirs : le liseré des cartes
            // la détache (SOC-26). Transparent hors OLED.
            .overlay {
                if !mine { bubbleShape(mine: false, first: isGroupStart, last: isGroupEnd).stroke(SQOledPalette.cardStroke, lineWidth: 1) }
            }
            .modifier(SpokenBubble(summary: spokenSummary, interactive: hasInteractiveContent))
    }

    /// Texte d'une bulle ; les liens y sont cliquables. La sélection libre n'est pas activée
    /// sur le texte : elle prendrait l'appui long au menu contextuel (« Sélectionner le texte »).
    @ViewBuilder
    private func bubbleText(_ text: String, id: String, mine: Bool) -> some View {
        if let linked = renderCache.linkedText(text, id: id) {
            Text(linked)
                .font(SQType.body)
                .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                .tint(mine ? SQColor.onInk : SQColor.accentInk)
                .accessibilityIdentifier("message.text")
        } else {
            Text(text)
                .font(SQType.body)
                .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                .accessibilityIdentifier("message.text")
        }
    }

    /// Photo, fichier ou note vocale pas encore partie : miniature de la photo (avec un voile
    /// et un indicateur pendant l'envoi), sinon la bulle dit ce qu'elle porte ; la légende suit.
    @ViewBuilder
    private func pendingAttachmentRow(_ attachment: PendingAttachmentSend, mine: Bool, localId: String) -> some View {
        let kind = attachment.kind.uppercased()
        if kind == "IMAGE", let data = attachment.data, let thumbnail = PendingThumbnailCache.image(for: localId, data: data) {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    if sendStatus[localId] == .sending {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .fill(SQColor.label.opacity(0.35))
                            .overlay { SQSpinner().tint(SQColor.onInk) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sendStatus[localId] == .sending ? "Photo en cours d’envoi" : "Photo non envoyée")
                .accessibilityIdentifier("message.pendingAttachment")
        } else {
            Label {
                switch kind {
                case "AUDIO": Text("Note vocale")
                case "FILE": Text(verbatim: attachment.filename)
                default: Text("Photo")
                }
            } icon: {
                Image(systemName: kind == "AUDIO" ? "waveform" : (kind == "FILE" ? "doc" : "photo"))
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
            .frame(minWidth: 120, alignment: .leading)
            .accessibilityIdentifier("message.pendingAttachment")
        }
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
                                    .font(SQType.micro)
                                    .foregroundStyle(reaction.mine ? SQColor.brandRed : SQColor.labelSecondary)
                            }
                        }
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 4)
                        .background {
                            // Base opaque `surface` (la capsule chevauche la bulle) ;
                            // ma réaction est cerclée de carmin.
                            Capsule(style: .continuous)
                                .fill(SQColor.surface)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(reaction.mine ? SQColor.brandRed : SQColor.separator, lineWidth: 1)
                                )
                        }
                        .sqShadowSoft()
                        // Zone tactile de 44 pt sans changer la hauteur de la capsule.
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .padding(.vertical, -10)
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
            .padding(.horizontal, SQSpace.sm2)
        }
    }

    /// Statut d'envoi optimiste dans la ligne méta (MSG-API-01). En cours :
    /// spinner discret (la bulle passe aussi à 0.7 d'opacité). L'échec est porté
    /// par `failedRetryRow`, SOUS la bulle (le danger sur fond encre serait illisible).
    @ViewBuilder
    private func sendStatusIndicator(for message: MessageItem) -> some View {
        if sendStatus[message.id] == .sending {
            if networkPath.isOnline {
                SQSpinner()
                    .controlSize(.mini)
                    .tint(SQColor.onInk.opacity(0.8))
                    .accessibilityLabel("Envoi en cours")
            } else {
                // Hors connexion, l'envoi attend le réseau : pas un spinner qui tourne sans fin (U02).
                Label("En attente de connexion", systemImage: "wifi.slash")
                    .font(SQType.micro(.regular))
                    .foregroundStyle(SQColor.onInk)
                    .accessibilityIdentifier("message.waitingForNetwork")
            }
        }
    }

    /// Échec d'envoi : capsule dangerSoft sous la bulle, tappable pour rejouer
    /// l'envoi (même Idempotency-Key, donc sans doublon serveur).
    private func failedRetryRow(for message: MessageItem) -> some View {
        let cause = pendingSends[message.id]?.failureReason ?? pendingAttachmentSends[message.id]?.failureReason
        return VStack(alignment: .trailing, spacing: 0) {
            failedRetryButtons(for: message)
            if let cause, !cause.isEmpty {
                Text(verbatim: cause)
                    .font(SQType.micro(.regular))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .accessibilityIdentifier("message.failureReason")
            }
        }
    }

    private func failedRetryButtons(for message: MessageItem) -> some View {
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
                .padding(.horizontal, SQSpace.sm2)
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
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("\(count) réponse")
                        .font(SQType.micro)
                }
                .foregroundStyle(SQColor.accentInk)
                .padding(.horizontal, SQSpace.xs)
                .padding(.vertical, 4)
                // Zone tactile de 44 pt sans changer la hauteur du badge.
                .padding(.vertical, 11)
                .contentShape(Rectangle())
                .padding(.vertical, -11)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func transcriptionView(_ text: String, mine: Bool) -> some View {
        HStack(alignment: .top, spacing: SQSpace.xs2) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(mine ? SQColor.onInk.opacity(0.75) : SQColor.labelSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(SQType.caption.italic())
                .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
        }
        .padding(.top, SQSpace.xs)
    }

    /// Coins asymétriques DA : le coin bas côté émetteur est plus petit,
    /// comme une « pointe » de bulle. Dans une série du même auteur, les coins
    /// côté émetteur se resserrent entre deux bulles.
    private func bubbleShape(mine: Bool, first: Bool = true, last: Bool = true) -> UnevenRoundedRectangle {
        let top: CGFloat = first ? SQRadius.xl : 8
        let bottom: CGFloat = last ? 6 : 8
        return UnevenRoundedRectangle(
            topLeadingRadius: mine ? SQRadius.xl : top,
            bottomLeadingRadius: mine ? SQRadius.xl : bottom,
            bottomTrailingRadius: mine ? bottom : SQRadius.xl,
            topTrailingRadius: mine ? top : SQRadius.xl,
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
        // Bulle encore locale (envoi en cours ou en échec) : le serveur ne la
        // connaît pas, ses boutons « Renvoyer » et « Supprimer » suffisent.
        let isLocal = message.id.hasPrefix("local-")
        let serverActions = EncryptedConversationSurfaces.allowsServerActions(messageId: message.id, isV2: conversationIsV2)
        if !isLocal {
            Button {
                beginReply(to: message)
            } label: {
                Label("Répondre", systemImage: "arrowshape.turn.up.left")
            }
        }
        if message.deletedAt == nil, serverActions {
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
            // Pas en conversation chiffrée : la sélection système contournerait la copie bornée ci-dessus.
            if !isE2EE {
                Button {
                    selectableText = SelectableText(text: displayedContent(for: message))
                } label: {
                    Label("Sélectionner le texte", systemImage: "text.cursor")
                }
            }
        }
        // Transférer : le texte seul, vers une conversation chiffrée si la source l'est (jamais l'inverse).
        if let forwardable = textOnlyContent(for: message) {
            Button {
                forwardTarget = ForwardPayload(text: forwardable, sourceIsEncrypted: isE2EE)
            } label: {
                Label("Transférer", systemImage: "arrowshape.turn.up.right")
            }
        }
        if message.deletedAt == nil, serverActions {
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
        if mine && message.deletedAt == nil && !isLocal {
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
        if !isLocal {
            Button(role: .destructive) {
                pendingDeletion = PendingMessageDeletion(message: message, forEveryone: false)
            } label: {
                Label("Supprimer pour moi", systemImage: "trash.slash")
            }
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

    /// Répondre à un message (menu contextuel ou glissement de la bulle). Quitter une
    /// modification pour répondre : le texte du message modifié ne devient pas la
    /// réponse, le brouillon revient.
    private func beginReply(to message: MessageItem) {
        if editTarget != nil {
            editTarget = nil
            restoreComposerAfterEdit()
        }
        replyTarget = message
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
        Button {
            emojiPickerTarget = message
        } label: {
            Label("Plus d’emojis", systemImage: "plus")
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
            openImageViewer(tappedId: attachment.id ?? url.absoluteString, accountSession: accountSession)
        } label: {
            Group {
                if let privateImageCacheScope {
                    RemoteImage(
                        url: attachment.url,
                        maxDimension: 240,
                        contentMode: .fill,
                        cacheScope: privateImageCacheScope,
                        // Sans état d'échec, le reflet tournait indéfiniment.
                        showsFailureUI: true
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

    /// Visionneuse sur toutes les photos de la conversation, ouverte à celle qu'on a touchée :
    /// on y passe de l'une à l'autre en balayant.
    private func openImageViewer(tappedId: String, accountSession: LocalAccountSession) {
        var targets: [MessageImageTarget] = []
        var initialIndex = 0
        for message in messages where message.deletedAt == nil {
            for attachment in message.attachments where isImageAttachment(attachment) {
                guard let url = attachment.url else { continue }
                let target = MessageImageTarget(
                    id: attachment.id ?? url.absoluteString,
                    url: url,
                    accountSession: accountSession
                )
                if target.id == tappedId { initialIndex = targets.count }
                targets.append(target)
            }
        }
        guard !targets.isEmpty else { return }
        imageViewer = ImageViewerSession(targets: targets, initialIndex: initialIndex)
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
                    .font(SQType.micro(.medium))
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
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                    .frame(width: 36, height: 36)
                    .background(mine ? SQColor.onInk.opacity(0.16) : SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.fileName ?? String(localized: "Pièce jointe"))
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileMetaLine(attachment))
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: SQSpace.sm)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(mine ? SQColor.onInk.opacity(0.9) : SQColor.brandRed)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.sm)
            .frame(minWidth: 200, alignment: .leading)
            .background(mine ? SQColor.onInk.opacity(0.10) : SQColor.surfaceMuted,
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
        return parts.isEmpty ? String(localized: "Fichier") : parts.joined(separator: " · ")
    }

    // MARK: Barre d'épinglés

    @ViewBuilder
    private var pinnedBar: some View {
        if !pinnedMessages.isEmpty {
            let pinned = pinnedMessages[min(pinnedIndex, pinnedMessages.count - 1)]
            Button {
                Haptics.selection()
                // Aussi pour un message plus ancien que les pages chargées, que le défilement seul n'atteint pas.
                handleSearchSelection(pinned.messageId)
                pinnedIndex = (min(pinnedIndex, pinnedMessages.count - 1) + 1) % pinnedMessages.count
            } label: {
                HStack(spacing: SQSpace.sm2) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pinnedMessages.count > 1 ? "\(pinnedMessages.count) messages épinglés" : "Message épinglé")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.accentInk)
                        Text(pinnedSnippet(pinned))
                            .font(SQType.subhead(.regular))
                            .foregroundStyle(SQColor.label)
                            .sqSingleLine()
                    }
                    Spacer(minLength: SQSpace.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm2)
                .frame(maxWidth: .infinity, minHeight: 44)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, SQSpace.md)
            .padding(.top, SQSpace.sm)
            .accessibilityIdentifier("conversation.pinned")
        }
    }

    private func pinnedSnippet(_ pinned: PinnedMessage) -> String {
        guard let message = pinned.message else { return String(localized: "Message") }
        if message.isEncrypted && !isReadableV2(message) {
            return decryptedMessages[message.id] ?? String(localized: "🔒 Message chiffré")
        }
        let value = message.content ?? ""
        return value.isEmpty ? String(localized: "Pièce jointe") : value
    }

    private static let typingRowId = "typing-indicator"

    /// Statut de `message` (mon dernier message) : Envoyé, Distribué ou Lu. Tant que `/receipts`
    /// n'a pas répondu, seul le « Lu » existant s'affiche ; derrière une bulle locale encore en
    /// file, « Envoyé » et « Distribué » seraient trompeurs et restent masqués.
    private func receiptStatus(for message: MessageItem) -> OwnMessageReceiptStatus? {
        guard let date = message.createdAt else { return nil }
        let status = OwnMessageReceiptStatus.resolve(
            messageDate: date,
            isGroup: conversation.isGroup,
            currentUserId: currentUserId,
            participantIds: conversation.participants.map(\.userId),
            readReceipts: readReceipts,
            deliveryReceipts: deliveryReceipts
        )
        guard status == .sent || status == .delivered else { return status }
        if !receiptsKnown { return nil }
        let pendingMineAfter = messages.last(where: { $0.senderId == currentUserId })?.id.hasPrefix("local-") == true
        return pendingMineAfter ? nil : status
    }

    /// Change quand le pied « Envoyé / Distribué / Lu » apparaît ou se modifie : sert à rester en bas de la liste.
    private var receiptFooterKey: String? {
        guard let last = messages.last(where: { $0.senderId == currentUserId && !$0.id.hasPrefix("local-") }),
              let status = receiptStatus(for: last) else { return nil }
        return "\(last.id)|\(status)"
    }

    @ViewBuilder
    private func readReceiptFooter(for lastMine: MessageItem) -> some View {
        if let status = receiptStatus(for: lastMine) {
            // Une coche pour « Envoyé », deux pour « Distribué » et « Lu » (accentuée) ;
            // en groupe, un lu partiel dit qui a vu. La seconde coche garde sa place
            // à « Envoyé » : le pied ne change pas de largeur.
            Group {
                if case .seenBy(let names) = status {
                    Text("Vu par \(names.joined(separator: ", "))")
                } else {
                    HStack(spacing: 4) {
                        ZStack(alignment: .leading) {
                            Image(systemName: "checkmark")
                            Image(systemName: "checkmark").offset(x: 5).opacity(status == .sent ? 0 : 1)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.trailing, 5)
                        .accessibilityHidden(true)
                        switch status {
                        case .delivered: Text("Distribué")
                        case .read: Text("Lu")
                        default: Text("Envoyé")
                        }
                    }
                }
            }
            .font(SQType.micro)
            .foregroundStyle(status == .read ? SQColor.accentInk : SQColor.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, SQSpace.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(receiptAccessibilityLabel(status))
            .accessibilityIdentifier("conversation.readReceipt")
        }
    }

    private func receiptAccessibilityLabel(_ status: OwnMessageReceiptStatus) -> String {
        switch status {
        case .sent: return String(localized: "Message envoyé")
        case .delivered: return String(localized: "Message distribué")
        case .read: return String(localized: "Message lu")
        case .seenBy(let names): return String(localized: "Vu par \(names.joined(separator: ", "))")
        }
    }

    /// Relit les accusés des autres membres (`/receipts`, v1 et v2). Faux si la route répond
    /// une erreur : les accusés déjà là restent, rien ne casse.
    @discardableResult
    private func refreshReceipts() async -> Bool {
        guard !AppEnvironment.usesDemoData,
              let fresh = try? await service.receipts(conversationId: conversation.id) else { return false }
        if fresh.readReceipts != readReceipts { readReceipts = fresh.readReceipts }
        if fresh.deliveryReceipts != deliveryReceipts { deliveryReceipts = fresh.deliveryReceipts }
        receiptsKnown = true
        return true
    }

    /// Un accusé d'un autre membre est arrivé par le flux : on relit `/receipts` après
    /// 400 ms (les événements se suivent par rafales), sans relire les messages. Si la
    /// route échoue, une conversation v1 relit la dernière page, comme avant.
    private func scheduleReceiptsRefresh() {
        receiptsTask?.cancel()
        receiptsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if await refreshReceipts() { return }
            if !usesV2 { await refreshLatestPageState() }
        }
    }

    /// Accuse réception du plus récent message d'autrui ; une seule fois par message, échec
    /// silencieux. En v1 l'identifiant est celui du message, en v2 celui de son enveloppe.
    private func acknowledgeDelivery() async {
        guard !AppEnvironment.usesDemoData, let currentUserId else { return }
        if usesV2 {
            guard let envelopeId = v2LastIncomingEnvelopeId else { return }
            await services.deliveryAcks.acknowledge(conversationId: conversation.id, messageId: envelopeId, using: service)
            return
        }
        guard let last = messages.last(where: { !$0.id.hasPrefix("local-") && $0.senderId != currentUserId }) else { return }
        await services.deliveryAcks.acknowledge(conversationId: conversation.id, messageId: last.id, using: service)
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if let typingUntil, typingUntil > Date() {
            HStack(alignment: .bottom, spacing: SQSpace.sm) {
                SQAvatar(
                    url: typingParticipant?.user.avatarUrl ?? conversation.groupPhotoUrl ?? otherParticipantAvatarURL,
                    name: typingParticipant?.user.displayName ?? conversationTitle,
                    size: 24
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // En groupe, dire qui écrit (prénom seulement, pour rester court).
                    if conversation.isGroup, let name = typingFirstName {
                        Text("\(name) écrit…")
                            .font(SQType.micro(.regular))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                    TypingDotsView()
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.sm2)
                        .background(SQColor.surface, in: bubbleShape(mine: false))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, SQSpace.sm)
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
            .accessibilityLabel(conversation.isGroup && typingFirstName != nil
                ? String(localized: "\(typingFirstName ?? "") est en train d’écrire")
                : String(localized: "En train d’écrire"))
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
        return renderCache.message(withId: replyToId, in: messages)
    }

    /// Horodatage de section centré (« Aujourd’hui 14:32 ») : affiché en tête de
    /// conversation, au changement de jour, ou après plus d'une heure de silence.
    private func sectionStamp(for message: MessageItem, previous: MessageItem?) -> String? {
        renderCache.stamp(for: message, previous: previous) { computeSectionStamp(for: message, previous: previous) }
    }

    private func computeSectionStamp(for message: MessageItem, previous: MessageItem?) -> String? {
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
        EncryptedConversationSurfaces.displayedText(for: message, usesV2: usesV2, decrypted: decryptedMessages)
    }

    private func isReadableV2(_ message: MessageItem) -> Bool {
        EncryptedConversationSurfaces.isReadableV2(message, usesV2: usesV2)
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

    /// Site partagé en texte (P2-47) : « Antenne … » du format commun, relu en carte. Il
    /// faut l'en-tête ET une ligne de donnée connue, sans quoi le texte reste un texte.
    /// Le texte clair ou déchiffré est lu ; mémoïsé par message dans `renderCache`.
    private func siteShare(for message: MessageItem, hasCard: Bool) -> SiteShareCard? {
        guard !hasCard, message.deletedAt == nil,
              location(for: message) == nil, pollsByMessageId[message.id] == nil else { return nil }
        let text = displayedContent(for: message)
        guard text.range(of: "antenne", options: .caseInsensitive) != nil else { return nil }
        return renderCache.siteShare(text, id: message.id)
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
        // Push, flux, relevé et retour au premier plan se recouvrent : une
        // seule relève à la fois, refaite une fois si une autre a été demandée,
        // pour qu'un résultat plus ancien n'écrase jamais un plus récent.
        guard !v2LoadInFlight else { v2LoadAgain = true; return }
        v2LoadInFlight = true
        defer { v2LoadInFlight = false }
        repeat {
            v2LoadAgain = false
            await loadV2Once()
        } while v2LoadAgain && !Task.isCancelled
    }

    private func loadV2Once() async {
        defer { hasLoadedOnce = true }
        switch await services.e2eeV2Messaging.thread(
            conversationId: conversation.id, isGroup: conversation.isGroup, participants: conversation.participants,
            limit: v2Limit
        ) {
        case .thread(let presentation):
            v2HasOlder = presentation.hasOlder
            // Un texte local que le serveur a déjà accepté (renvoyé par la reprise en arrière-plan,
            // ou passé juste avant la coupure) n'a plus à rester « non envoyé » (B02).
            let accepted = presentation.clientRequestIds
            for (localId, pending) in pendingSends where accepted.contains(pending.idempotencyKey) {
                pendingSends[localId] = nil
                sendStatus[localId] = nil
            }
            let localPending = messages.filter { pendingSends[$0.id] != nil || pendingAttachmentSends[$0.id] != nil }
            let restored = await restoredV2Messages(accepted: accepted)
            let hidden = E2EEV2HiddenMessagesStore.hiddenRefs(conversationId: conversation.id)
            let knownIds = Set(messages.map(\.id))
            let thread = presentation.messages.filter { !hidden.contains($0.id) }
            let merged = Self.normalized(thread + localPending + restored)
            // Le message envoyé peut arriver par le flux avant l'accusé : sa bulle locale s'efface alors.
            let confirmed = localIdsConfirmed(by: thread.filter { !knownIds.contains($0.id) })
            let next = confirmed.isEmpty ? merged : merged.filter { !confirmed.contains($0.id) }
            if next != messages { messages = next }
            v2Notices = presentation.notices
            v2LastIncomingEnvelopeId = presentation.lastIncomingEnvelopeId
            computeUnreadDividerIfNeeded()
            Task { await acknowledgeDelivery() }
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
        if let failure = EncryptedConversationSurfaces.v2SendFailureMessage(result) {
            showActionError(failure)
            return false
        }
        await loadV2()
        return true
    }

    // MARK: Envois v2 gardés (B02)

    /// Garde le texte dans la file durable avant l'envoi : s'il échoue, il survit à la sortie de
    /// l'écran, et la reprise en arrière-plan le rejoue sous le même identifiant.
    private func stageV2Send(_ pending: PendingSend) async {
        guard let scope = LocalAccountScope.sessionSnapshot()?.ownerScopeId else { return }
        try? await MessageDraftStore.shared.stageV2Send(
            .init(
                clientRequestId: pending.idempotencyKey, conversationId: conversation.id, isGroup: conversation.isGroup,
                participantIds: conversation.participants.map(\.userId), text: pending.text, replyToRef: pending.replyToId,
                ttlSeconds: pending.ttlSeconds, createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            ownerScopeId: scope
        )
    }

    private func removeV2Send(clientRequestId: String) async {
        guard let scope = LocalAccountScope.sessionSnapshot()?.ownerScopeId else { return }
        await MessageDraftStore.shared.removeV2Send(clientRequestId: clientRequestId, ownerScopeId: scope)
    }

    /// Textes v2 restés dans la file durable (envoi refusé, appli quittée) : ils reviennent en bulles
    /// « Non envoyé » avec Renvoyer / Supprimer. Ceux que le serveur a déjà acceptés quittent la file.
    private func restoredV2Messages(accepted: Set<String>) async -> [MessageItem] {
        guard let scope = LocalAccountScope.sessionSnapshot()?.ownerScopeId else { return [] }
        let known = Set(pendingSends.values.map(\.idempotencyKey))
        var restored: [MessageItem] = []
        for record in await MessageDraftStore.shared.pendingV2Sends(ownerScopeId: scope, conversationId: conversation.id) {
            if accepted.contains(record.clientRequestId) {
                await MessageDraftStore.shared.removeV2Send(clientRequestId: record.clientRequestId, ownerScopeId: scope)
                continue
            }
            guard !known.contains(record.clientRequestId) else { continue }
            let localId = "local-\(record.clientRequestId)"
            pendingSends[localId] = PendingSend(
                text: record.text, replyToId: record.replyToRef, idempotencyKey: record.clientRequestId,
                ttlSeconds: record.ttlSeconds, restored: true
            )
            sendStatus[localId] = .failed
            restored.append(makeOptimisticMessage(
                id: localId, text: record.text, replyToId: record.replyToRef,
                createdAt: Date(timeIntervalSince1970: Double(record.createdAtMs) / 1_000)
            ))
        }
        return restored
    }

    /// Calculé une fois, à la première lecture : les messages qui arrivent ensuite ne déplacent pas le repère.
    private func computeUnreadDividerIfNeeded() {
        guard !unreadDividerComputed, messages.contains(where: { !$0.id.hasPrefix("local-") }) else { return }
        unreadDividerComputed = true
        unreadDivider = UnreadDivider.make(messages: messages, lastReadAt: conversation.lastReadAt, currentUserId: currentUserId)
    }

    private func load() async {
        defer { hasLoadedOnce = true }
        if AppEnvironment.usesDemoData {
            messages = conversation.lastMessage.map { [$0] } ?? MessageItem.demo
            errorMessage = nil
            return
        }
        // La reprise ne doit jamais retarder l'ouverture de la conversation. Le backend
        // deduplique par clientRequestId si deux ouvertures reveillent la meme ligne.
        // Les pièces jointes en file ne repartent plus en silence ici : elles reviennent
        // en bulles « Non envoyé » (Renvoyer / Supprimer), voir `restoredPendingAttachments`.
        Task { await service.retryPendingTextMessages() }
        do {
            let page = try await service.messages(conversationId: conversation.id, cursor: nil)
            // Les bulles locales encore en cours d'envoi (ou en échec, rejouables)
            // ne sont pas encore sur le serveur : un rechargement ne doit pas les
            // faire disparaître.
            let localPending = messages.filter { pendingSends[$0.id] != nil || pendingAttachmentSends[$0.id] != nil }
            messages = Self.normalized(page.messages + localPending + (await restoredFailedMessages()) + (await restoredPendingAttachments()))
            computeUnreadDividerIfNeeded()
            olderCursor = (page.hasMore ?? (page.nextCursor != nil)) ? page.nextCursor : nil
            if !receiptsKnown { readReceipts = page.readReceipts ?? [] }
            errorMessage = nil
            advanceLastSync(with: page.messages)
            await refreshE2EEState()
            await decryptLoadedMessages()
            refreshPolls()
            await acknowledgeDelivery()
            await refreshReceipts()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Bulles locales « en cours d'envoi » dont le message serveur vient d'arriver par le flux
    /// avant la réponse HTTP : sans ça, le texte s'affichait deux fois un instant. Chaque message
    /// serveur n'en confirme qu'une (deux « ok » d'affilée), et seuls les messages nouveaux comptent.
    private func localIdsConfirmed(by arrived: [MessageItem]) -> Set<String> {
        var free = arrived.filter { $0.senderId == currentUserId && !$0.id.hasPrefix("local-") }
        guard !free.isEmpty else { return [] }
        var confirmed = Set<String>()
        for local in messages where sendStatus[local.id] == .sending {
            if let pending = pendingSends[local.id] {
                guard let hit = free.firstIndex(where: {
                    $0.replyToId == pending.replyToId && displayedContent(for: $0) == pending.text
                }) else { continue }
                free.remove(at: hit)
                confirmed.insert(local.id)
            } else if let attachment = pendingAttachmentSends[local.id], attachment.clientRequestId == nil {
                let kind = attachment.kind.uppercased()
                guard let hit = free.firstIndex(where: { item in
                    item.replyToId == attachment.replyToId
                        && displayedContent(for: item) == attachment.caption
                        && item.attachments.contains { $0.kind.uppercased() == kind }
                }) else { continue }
                free.remove(at: hit)
                confirmed.insert(local.id)
            }
        }
        return confirmed
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
        if usesV2 {
            await loadOlderV2()
            return
        }
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
            await syncCallHistory()
        } catch {
            // Silencieux : l'historique déjà chargé reste utilisable.
        }
    }

    /// Fil v2 : la page précédente vient du magasin local, sans réseau.
    private func loadOlderV2() async {
        guard v2HasOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let anchorId = messages.first?.id
        v2Limit += E2EEV2ThreadWindow.pageSize
        await loadV2()
        prependAnchorId = anchorId
        await syncCallHistory()
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
                case .typingEvent(let userIds):
                    await MainActor.run {
                        // Le serveur renvoie aussi notre propre frappe : seule celle des autres compte.
                        let others = userIds.filter { $0 != currentUserId }
                        guard let typer = others.first else { return }
                        typingUserId = typer
                        withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { typingUntil = Date().addingTimeInterval(5) }
                    }
                case .viewingEvent:
                    await refreshViewers()
                case .callEvent(let event):
                    await MainActor.run { acceptCallEvent(event) }
                case .receiptsEvent(let userId):
                    // Notre propre « lu » ou « distribué » revient aussi par le flux : sans objet.
                    if let userId, userId == currentUserId { continue }
                    scheduleReceiptsRefresh()
                case .stateEvent:
                    await MainActor.run { if threadTarget != nil { threadRefreshToken &+= 1 } }
                    // Les événements d'état que provoque notre propre « lu » reviennent dans la seconde :
                    // on laisse passer ce délai plutôt que de relire 80 messages pour rien.
                    let sinceOwnRead = Date().timeIntervalSince(readGate.lastMarkReadAt)
                    if sinceOwnRead < 1 { try? await Task.sleep(nanoseconds: UInt64((1 - sinceOwnRead) * 1_000_000_000)) }
                    // Une conversation v2 ne se relit jamais par la page v1.
                    if usesV2 { await loadV2() } else { await refreshLatestPageState() }
                case .serverEvent, .polling:
                    await MainActor.run { if threadTarget != nil { threadRefreshToken &+= 1 } }
                    // Le flux ne rejoue pas les appels terminés pendant une coupure : on relit les plus récents.
                    if trigger == .polling { await refreshRecentCalls() }
                    if usesV2 {
                        await loadV2()
                        await markReadIfLastIncoming()
                    } else {
                        await refreshDelta()
                    }
                }
            }
            MessageSyncLog.logger.debug("sync stream ended \(conversationId, privacy: .public)")
        }
    }

    private func stopSync() {
        syncTask?.cancel()
        syncTask = nil
        receiptsTask?.cancel()
        receiptsTask = nil
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
            viewersKnown = true
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
            let confirmed = localIdsConfirmed(by: fresh.filter { !knownIds.contains($0.id) })
            if !confirmed.isEmpty { messages.removeAll { confirmed.contains($0.id) } }
            refreshPolls()
            await loadPinned()
            await acknowledgeDelivery()
            await markRead()
        } catch {
            MessageSyncLog.logger.error("delta erreur: \(error.localizedDescription, privacy: .public)")
            SQDiagnostics.record(error, area: .messageSync)
        }
    }

    // MARK: Appels dans le fil

    /// Rangée centrée d'un appel terminé : toucher rappelle, dans le même mode.
    private func callRow(_ event: CallThreadEvent) -> some View {
        let missed = event.isMissedForReader(currentUserId: currentUserId)
        let summary = event.summary(currentUserId: currentUserId)
        let time = event.startedAt.formatted(date: .omitted, time: .shortened)
        let canRecall = SQFeatures.callsEnabled && networkPath.isOnline
        return Button {
            Haptics.selection()
            startCall(mode: event.mode == .video ? "video" : "audio")
        } label: {
            HStack(spacing: SQSpace.xs) {
                Image(systemName: event.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: summary)
                    .font(SQType.micro)
                Text(verbatim: time)
                    .font(SQType.micro(.regular))
                    .monospacedDigit()
                    .opacity(0.8)
            }
            .foregroundStyle(missed ? SQColor.dangerInk : SQColor.chipInk)
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, 4)
            .background(missed ? SQColor.dangerSoft : SQColor.chip, in: Capsule(style: .continuous))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRecall)
        .frame(maxWidth: .infinity)
        .id("call-\(event.callId)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(summary), \(time)"))
        .accessibilityHint(canRecall ? Text("Rappeler") : Text(verbatim: ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("conversation.callRow")
    }

    /// Route absente ou refusée : le fil reste sans appels, sans message d'erreur.
    private func callsAreUnavailable(_ error: Error) -> Bool {
        guard case APIError.http(let status, _, _, _, _) = error else { return false }
        return [403, 404, 405, 501].contains(status)
    }

    /// Charge l'historique d'appels jusqu'à couvrir la plage de dates des messages
    /// chargés ; tout l'historique quand il n'y a plus de messages plus anciens.
    private func syncCallHistory() async {
        guard !callsUnavailable, !callsLoading, !callsExhausted else { return }
        callsLoading = true
        defer { callsLoading = false }
        let hasOlderMessages = usesV2 ? v2HasOlder : olderCursor != nil
        let coverFrom: Date? = hasOlderMessages ? messages.compactMap(\.createdAt).min() : nil
        for _ in 0..<5 {
            if let coverFrom, callsFetchedOnce, let oldest = callEvents.last?.startedAt, oldest <= coverFrom { break }
            do {
                let page = try await service.callThreadHistory(conversationId: conversation.id, before: callsNextBefore, limit: 50)
                guard !Task.isCancelled else { return }
                callEvents = CallThreadPlacement.merge(callEvents, with: page.events)
                callsFetchedOnce = true
                callsNextBefore = page.nextBefore
                if page.nextBefore == nil || page.events.isEmpty {
                    callsExhausted = true
                    break
                }
            } catch {
                if callsAreUnavailable(error) {
                    callsUnavailable = true
                    callEvents = []
                }
                break
            }
        }
    }

    /// Relit la page la plus récente : après une coupure du flux, ou un appel dont le corps n'a pas pu être lu.
    private func refreshRecentCalls() async {
        guard !callsUnavailable, !AppEnvironment.usesDemoData,
              Date().timeIntervalSince(lastCallRefresh) > 30 else { return }
        lastCallRefresh = Date()
        do {
            let page = try await service.callThreadHistory(conversationId: conversation.id, before: nil, limit: 20)
            callEvents = CallThreadPlacement.merge(callEvents, with: page.events)
        } catch {
            if callsAreUnavailable(error) {
                callsUnavailable = true
                callEvents = []
            }
        }
    }

    /// Appel annoncé par le flux : inséré, sans doublon avec l'historique déjà chargé.
    private func acceptCallEvent(_ event: CallThreadEvent?) {
        guard !callsUnavailable else { return }
        guard let event else {
            lastCallRefresh = .distantPast
            Task { await refreshRecentCalls() }
            return
        }
        callEvents = CallThreadPlacement.merge(callEvents, with: [event])
    }

    // MARK: Conversation protégée

    /// Face ID n'est exigé que si l'appareil sait authentifier son propriétaire.
    private var protectionRequiresUnlock: Bool {
        secretPolicy?.requireBiometric == true && BiometricAuth.canAuthenticateDeviceOwner
    }

    /// Réglage jamais lu sur cet appareil : le fil reste masqué le temps de le lire.
    private var policyIsUnresolved: Bool {
        secretPolicy == nil && !policyFetchGaveUp && !AppEnvironment.usesDemoData
    }

    /// Le fil ne doit être ni lu ni marqué comme lu.
    private var holdsProtection: Bool {
        policyIsUnresolved || (protectionRequiresUnlock && !protectionUnlocked)
    }

    private var showsProtectionVeil: Bool {
        holdsProtection
            || (protectionRequiresUnlock && scenePhase != .active)
            || (secretPolicy?.blockScreenshots == true && isScreenCaptured)
    }

    private var shouldPromptUnlock: Bool {
        protectionRequiresUnlock && !protectionUnlocked && scenePhase == .active && !policyIsUnresolved
    }

    private var protectionVeil: some View {
        let recording = secretPolicy?.blockScreenshots == true && isScreenCaptured && !holdsProtection
        return ZStack {
            SQColor.bg.ignoresSafeArea()
            if policyIsUnresolved {
                SQSpinner().tint(SQColor.brandRed)
                    .accessibilityLabel("Chargement")
            } else if recording {
                protectionMessage(
                    systemImage: "record.circle",
                    title: "Enregistrement d’écran en cours",
                    detail: String(localized: "Le fil est masqué tant que l’écran est enregistré ou diffusé."),
                    unlockable: false
                )
            } else if protectionRequiresUnlock && !protectionUnlocked {
                protectionMessage(
                    systemImage: BiometricAuth.kind.systemImage,
                    title: "Conversation protégée",
                    detail: String(localized: "Déverrouille avec \(BiometricAuth.kind.label) pour lire ce fil."),
                    unlockable: scenePhase == .active
                )
            } else {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if !inSplitDetail {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "conversation.veil.back") { closeConversation() }
                    .padding(SQSpace.lg)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.veil")
    }

    private func protectionMessage(systemImage: String, title: LocalizedStringKey, detail: String, unlockable: Bool) -> some View {
        VStack(spacing: SQSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 64, height: 64)
                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(SQType.stateTitle)
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: detail)
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if unlockable {
                GradientButton(String(localized: "Déverrouiller"), systemImage: BiometricAuth.kind.systemImage, isBusy: isAuthenticating) {
                    Task { await unlockProtection() }
                }
                .fixedSize()
                .accessibilityIdentifier("conversation.veil.unlock")
            }
        }
        .padding(SQSpace.xl)
        .frame(maxWidth: 420)
    }

    private func unlockProtection() async {
        guard !isAuthenticating, protectionRequiresUnlock else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let granted = await BiometricAuth.authenticate(
            reason: String(localized: "Déverrouille cette conversation protégée."),
            allowPasscode: true
        )
        guard granted else { return }
        protectionUnlocked = true
        // Le fil est lisible : la lecture et l'accusé reprennent là où ils étaient retenus.
        await acknowledgeDelivery()
        await markReadIfLastIncoming()
    }

    /// Lit le réglage du serveur et garde-le pour la prochaine ouverture.
    private func refreshSecretPolicy() async {
        guard !AppEnvironment.usesDemoData else { return }
        if let known = secretPolicy { applySecretPolicy(known) }
        do {
            let fresh = try await service.secretPolicy(conversationId: conversation.id)
            ConversationSecretPolicyCache.store(fresh, conversationId: conversation.id)
            applySecretPolicy(fresh)
        } catch {
            // Sans réglage connu ni réseau, le fil s'ouvre : rien ne dit qu'il est protégé.
            if secretPolicy == nil { policyFetchGaveUp = true }
        }
    }

    private func applySecretPolicy(_ policy: ConversationSecretPolicy) {
        secretPolicy = policy
        ConversationSecretPolicyCache.store(policy, conversationId: conversation.id)
        if policy.ephemeralDefault, !ephemeralDefaultApplied {
            ephemeralDefaultApplied = true
            ephemeralEnabled = true
        }
    }

    /// Fenêtres qui montrent du contenu du fil : refermées quand le fil se reverrouille.
    private func dismissContentPresentations() {
        threadTarget = nil
        selectableText = nil
        forwardTarget = nil
        imageViewer = nil
        sharedPostComments = nil
        sharedPostDetail = nil
        showSearch = false
        showMedia = false
        showScheduled = false
        showReminders = false
        showSaved = false
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
            while !messages.contains(where: { $0.id == messageId }), olderCursor != nil || v2HasOlder, pages < 10 {
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
        // Des pièces jointes attendent : elles partent, le texte en légende.
        if editTarget == nil, !stagedAttachments.isEmpty {
            await sendStaged(caption: text)
            return
        }
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
                let edited = editTarget
                self.editTarget = nil
                restoreComposerAfterEdit()
                // Mise à jour sur place : relire la première page effaçait l'historique déjà paginé.
                messages = messages.map { $0.id == edited.id ? Self.copy(of: $0, content: $0.isEncrypted ? nil : text, editedAt: Date()) : $0 }
                await refreshLatestPageState()
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
        let ttl = ephemeralTTL
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
        if pendingAttachmentSends[localId] != nil {
            await performAttachmentSend(localId: localId)
            return
        }
        guard let pending = pendingSends[localId] else { return }
        guard !v2Unavailable else {
            sendStatus[localId] = .failed
            return
        }
        sendStatus[localId] = .sending
        if usesV2 {
            // Gardé sur l'appareil avant l'envoi (B02), puis même clientRequestId à chaque essai :
            // l'enveloppe gardée repart à l'octet.
            await stageV2Send(pending)
            if await sendV2(.text(pending.text), replyToId: pending.replyToId, ttlSeconds: pending.ttlSeconds,
                            clientRequestId: pending.idempotencyKey) {
                messages.removeAll { $0.id == localId }
                sendStatus[localId] = nil
                pendingSends[localId] = nil
                await removeV2Send(clientRequestId: pending.idempotencyKey)
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
            // Pas de second retour haptique ici : le léger de l'envoi suffit.
            // Premier message envoyé : le bon moment pour proposer d'être
            // prévenu des réponses (TRX-01), une seule fois par appareil.
            Task { await services.notificationPriming.considerPriming(after: .messageSent) }
        } catch {
            // On conserve la bulle et les données de rejeu : l'utilisateur peut
            // réessayer d'un tap. Pas de bannière d'erreur globale ici — le
            // feedback est porté par la bulle elle-même, avec la cause.
            pendingSends[localId]?.failureReason = error.userFacingMessage
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
                ttlSeconds: record.request.ttlSeconds ?? 0, restored: true, failureReason: record.failureReason
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
            // Un texte v2 abandonné ne doit plus repartir avec la reprise en arrière-plan.
            await removeV2Send(clientRequestId: pending.idempotencyKey)
        }
        if let attachment = pendingAttachmentSends[localId] {
            await discardOutboxRecords(for: attachment)
        }
        pendingSends[localId] = nil
        pendingAttachmentSends[localId] = nil
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
        // Même limite que les images : le chiffrement des pièces jointes
        // n'est pas encore disponible partout. Le dire plutôt que d'envoyer
        // un audio en clair dans une conversation chiffrée.
        guard !isE2EE else {
            showActionError(String(localized: "Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils."))
            Haptics.error()
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        await queueAttachment(
            PendingAttachmentSend(
                data: data, filename: url.lastPathComponent, mimeType: "audio/m4a", kind: "AUDIO",
                caption: "", width: nil, height: nil, replyToId: replyTarget?.id, ttlSeconds: ephemeralTTL
            )
        )
        replyTarget = nil
    }

    /// Plusieurs photos choisies d'un coup : envoyées l'une après l'autre, la légende sur la première.
    private func sendPhotos(_ items: [PhotosPickerItem], caption: String) async {
        for (index, item) in items.enumerated() {
            await sendAttachment(item: item, caption: index == 0 ? caption : "")
        }
    }

    private func sendAttachment(item: PhotosPickerItem, caption rawCaption: String) async {
        do {
            guard !isE2EE else {
                throw E2EEError.unsupported(String(localized: "Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils."))
            }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                await sendVideo(item: item, caption: rawCaption)
                return
            }
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                // Photo pas encore téléchargée d'iCloud, ou réseau coupé : le dire (B10).
                showActionError(String(localized: "Photo indisponible. Réessaie avec du réseau."))
                Haptics.error()
                return
            }
            await sendPhoto(rawData: raw, caption: rawCaption)
        } catch {
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
    }

    /// Vidéo de la photothèque : copiée dans un fichier temporaire (jamais chargée entière en
    /// mémoire avant d'en connaître la taille), puis envoyée comme fichier.
    private func sendVideo(item: PhotosPickerItem, caption rawCaption: String) async {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            showActionError(String(localized: "Vidéo indisponible. Réessaie avec du réseau."))
            Haptics.error()
            return
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard MessageAttachmentOutboxStore.fits(size), let data = try? Data(contentsOf: movie.url, options: .mappedIfSafe),
              MessageAttachmentOutboxStore.fits(data.count) else {
            showActionError(size > 0
                ? String(localized: "Cette vidéo dépasse 10 Mo. Choisis-en une plus courte.")
                : String(localized: "Cette vidéo est illisible."))
            Haptics.error()
            return
        }
        let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
        await queueAttachment(
            PendingAttachmentSend(
                data: data, filename: "video.\(ext)",
                mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime", kind: "FILE",
                caption: rawCaption.trimmingCharacters(in: .whitespacesAndNewlines), width: nil, height: nil,
                replyToId: replyTarget?.id, ttlSeconds: ephemeralTTL
            )
        )
        draftAutosaver?.discard()
        clearComposer()
        replyTarget = nil
    }

    /// Document choisi dans Fichiers : part tel quel, en pièce jointe « fichier » (téléchargement
    /// forcé côté serveur), dans la limite de 10 Mo.
    private func sendFile(at url: URL, caption rawCaption: String) async {
        guard !isE2EE else {
            showFilesUnavailable()
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard MessageAttachmentOutboxStore.fits(size), let data = try? Data(contentsOf: url),
              MessageAttachmentOutboxStore.fits(data.count) else {
            showActionError(size > MessageAttachmentOutboxStore.maximumSourceBytes
                ? String(localized: "Ce fichier dépasse 10 Mo.")
                : String(localized: "Ce fichier est illisible."))
            Haptics.error()
            return
        }
        await queueAttachment(
            PendingAttachmentSend(
                data: data, filename: url.lastPathComponent,
                mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                kind: "FILE", caption: rawCaption.trimmingCharacters(in: .whitespacesAndNewlines),
                width: nil, height: nil, replyToId: replyTarget?.id, ttlSeconds: ephemeralTTL
            )
        )
        draftAutosaver?.discard()
        clearComposer()
        replyTarget = nil
    }

    // MARK: Pièces jointes en attente (partage reçu, glisser-déposer, coller)

    private static let maxStagedAttachments = 10

    /// Envoie les pièces en attente par le chemin habituel, l'une après l'autre ;
    /// le texte tapé est la légende de la première (comme pour plusieurs photos).
    private func sendStaged(caption: String) async {
        let items = stagedAttachments
        stagedAttachments = []
        guard !isE2EE else {
            showActionError(String(localized: "Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils."))
            Haptics.error()
            return
        }
        for (index, item) in items.enumerated() {
            await queueAttachment(
                PendingAttachmentSend(
                    data: item.data, filename: item.filename, mimeType: item.mimeType, kind: item.kind,
                    caption: index == 0 ? caption : "", width: item.width, height: item.height,
                    replyToId: replyTarget?.id, ttlSeconds: ephemeralTTL
                )
            )
            draftAutosaver?.discard()
            clearComposer()
            replyTarget = nil
        }
    }

    /// Met une photo, une vidéo ou un fichier en attente dans le compositeur, avec
    /// les mêmes règles et limites que les envois directs.
    private func stage(data: Data, fileName: String, uti: String) async {
        let type = UTType(uti) ?? UTType(filenameExtension: (fileName as NSString).pathExtension)
        let isImage = type?.conforms(to: .image) == true
        guard !isE2EE else {
            if isImage {
                showActionError(String(localized: "Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils."))
            } else {
                showFilesUnavailable()
            }
            Haptics.error()
            return
        }
        guard stagedAttachments.count < Self.maxStagedAttachments else {
            showActionError(String(localized: "Tu peux joindre 10 éléments au plus à la fois."))
            Haptics.error()
            return
        }
        if isImage {
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                Self.preparedJPEG(from: data)
            }).value, MessageAttachmentOutboxStore.fits(prepared.data.count) else {
                showActionError(String(localized: "Image illisible."))
                Haptics.error()
                return
            }
            stagedAttachments.append(StagedAttachment(
                data: prepared.data, filename: "photo.jpg", mimeType: "image/jpeg", kind: "IMAGE",
                width: prepared.width, height: prepared.height
            ))
        } else {
            let isVideo = type?.conforms(to: .movie) == true
            guard MessageAttachmentOutboxStore.fits(data.count) else {
                showActionError(data.count > MessageAttachmentOutboxStore.maximumSourceBytes
                    ? (isVideo ? String(localized: "Cette vidéo dépasse 10 Mo. Choisis-en une plus courte.") : String(localized: "Ce fichier dépasse 10 Mo."))
                    : String(localized: "Ce fichier est illisible."))
                Haptics.error()
                return
            }
            let ext = (fileName as NSString).pathExtension
            stagedAttachments.append(StagedAttachment(
                data: data,
                filename: isVideo ? "video.\(ext.isEmpty ? "mov" : ext)" : fileName,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream", kind: "FILE",
                width: nil, height: nil
            ))
        }
        Haptics.light()
    }

    /// Texte glissé ou collé : ajouté à la suite de ce qui est tapé, sans écraser.
    private func insertIntoComposer(_ text: String) {
        guard editTarget == nil, !text.isEmpty else { return }
        let current = draftAutosaver?.text ?? ""
        let separator = current.isEmpty || current.last?.isWhitespace == true ? "" : "\n"
        let merged = current + separator + text
        seedComposer(merged)
        draftAutosaver?.textChanged(merged)
    }

    /// Ce qui est glissé sur la conversation, ou collé depuis le menu « + ».
    private func importProviders(_ providers: [NSItemProvider]) async {
        guard canSend, editTarget == nil else { return }
        var texts: [String] = []
        for item in await ConversationInputImport.items(from: providers) {
            switch item {
            case .text(let value):
                texts.append(value)
            case .file(let file):
                await stage(data: file.data, fileName: file.fileName, uti: file.uti)
            case .failure(let failure):
                showActionError(failure.message)
                Haptics.error()
            }
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= ShareInbox.maxTextCharacters else {
            showActionError(String(localized: "Ce texte est trop long : 4 000 caractères au plus."))
            Haptics.error()
            return
        }
        insertIntoComposer(text)
    }

    /// « Coller » : le presse-papiers n'est lu qu'à cet appui. Les tests de contenu
    /// (`hasStrings`…) ne le déclenchent pas.
    private func pasteFromClipboard() async {
        guard canSend, editTarget == nil else { return }
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings || pasteboard.hasImages || pasteboard.hasURLs else {
            showActionError(String(localized: "Le presse-papiers ne contient rien à coller."))
            Haptics.error()
            return
        }
        await importProviders(pasteboard.itemProviders)
    }

    /// Partage reçu : le texte (déjà dans le brouillon de la conversation) revient
    /// dans le champ, les pièces jointes passent en attente.
    private func consumePendingShare() async {
        guard let handoff = router.pendingShare, handoff.conversationId == conversation.id else { return }
        router.pendingShare = nil
        guard handoff.isFresh else { return }
        await restoreDraftIfNeeded()
        if editTarget == nil, let autosaver = draftAutosaver {
            let stored = await MessageDraftStore.shared.text(
                conversationId: conversation.id, ownerScopeId: LocalAccountScope.currentOwnerScopeId
            ) ?? ""
            if !stored.isEmpty, stored != autosaver.text {
                seedComposer(stored)
                autosaver.textChanged(stored)
            }
        }
        for attachment in handoff.attachments {
            await stage(data: attachment.data, fileName: attachment.fileName, uti: attachment.uti)
        }
    }

    /// Photo prise avec l'appareil : même chemin que celles de la photothèque.
    private func sendCapturedPhoto(_ data: Data, caption: String) async {
        guard !isE2EE else {
            showActionError(String(localized: "Les pièces jointes chiffrées ne sont pas encore disponibles sur tous tes appareils."))
            Haptics.error()
            return
        }
        await sendPhoto(rawData: data, caption: caption)
    }

    private func sendPhoto(rawData raw: Data, caption rawCaption: String) async {
        // Décodage/redimensionnement/encodage hors du main thread pour ne pas
        // geler l'UI pendant l'envoi (image plein format).
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            Self.preparedJPEG(from: raw)
        }).value else {
            showActionError(String(localized: "Image illisible."))
            Haptics.error()
            return
        }
        let caption = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        await queueAttachment(
            PendingAttachmentSend(
                data: prepared.data, filename: "photo.jpg", mimeType: "image/jpeg", kind: "IMAGE",
                caption: caption, width: prepared.width, height: prepared.height,
                replyToId: replyTarget?.id, ttlSeconds: ephemeralTTL
            )
        )
        // La légende envoyée ne doit pas revenir comme brouillon.
        draftAutosaver?.discard()
        clearComposer()
        replyTarget = nil
    }

    /// Pose tout de suite la bulle de la pièce jointe (en cours d'envoi), puis la téléverse.
    /// Le téléversement ne bloque plus la barre de saisie : on peut continuer à écrire.
    private func queueAttachment(_ attachment: PendingAttachmentSend) async {
        let localId = "local-att-\(UUID().uuidString)"
        pendingAttachmentSends[localId] = attachment
        sendStatus[localId] = .sending
        let optimistic = makeOptimisticMessage(
            id: localId, text: attachment.caption, replyToId: attachment.replyToId, ttlSeconds: attachment.ttlSeconds
        )
        messages = Self.normalized(messages + [optimistic])
        Haptics.light()
        await performAttachmentSend(localId: localId)
    }

    /// Envoie (ou renvoie) une pièce jointe. Les mêmes octets repartent avec le même
    /// enregistrement de la file durable (même identifiant de requête côté service) : pas de doublon.
    private func performAttachmentSend(localId: String) async {
        guard let attachment = pendingAttachmentSends[localId] else { return }
        withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { sendStatus[localId] = .sending }
        guard let data = attachment.data else {
            // Venue de la file durable : le service sait la rejouer, pas cette vue. « Renvoyer » vise
            // cette pièce précisément, même si un refus définitif l'avait mise de côté (B03).
            if let requestId = attachment.clientRequestId {
                do {
                    _ = try await service.resendPendingAttachment(clientRequestId: requestId)
                } catch {
                    pendingAttachmentSends[localId]?.failureReason = error.userFacingMessage
                }
            } else {
                await service.retryPendingAttachments()
            }
            await pruneSettledRestoredAttachments()
            if pendingAttachmentSends[localId] != nil {
                withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { sendStatus[localId] = .failed }
                Haptics.error()
            } else {
                await refreshLatestPageState()
            }
            return
        }
        do {
            let sent = try await service.sendAttachmentData(
                data,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                kind: attachment.kind,
                caption: attachment.caption,
                width: attachment.width,
                height: attachment.height,
                in: conversation,
                replyToId: attachment.replyToId,
                e2ee: e2ee,
                ttlSeconds: attachment.ttlSeconds
            )
            var next = messages.filter { $0.id != localId }
            next.append(sent)
            messages = Self.normalized(next)
            if sent.isEncrypted, !attachment.caption.isEmpty {
                decryptedMessages[sent.id] = attachment.caption
            }
            sendStatus[localId] = nil
            pendingAttachmentSends[localId] = nil
        } catch {
            pendingAttachmentSends[localId]?.failureReason = error.userFacingMessage
            withAnimation(SQMotion.resolve(SQMotion.fast, reduceMotion)) { sendStatus[localId] = .failed }
            showActionError(error.userFacingMessage)
            Haptics.error()
        }
    }

    /// Pièces jointes restées dans la file durable pour cette conversation : elles reviennent en
    /// bulles « Non envoyé ». Ignorées tant qu'un envoi de cette vue est en cours, car sa propre
    /// ligne de file ne se distingue pas d'une ligne restée d'une session précédente.
    private func restoredPendingAttachments() async -> [MessageItem] {
        guard !pendingAttachmentSends.values.contains(where: { $0.clientRequestId == nil }) else { return [] }
        let known = Set(pendingAttachmentSends.values.compactMap(\.clientRequestId))
        var restored: [MessageItem] = []
        for record in await service.pendingAttachments(conversationId: conversation.id)
        where !known.contains(record.clientRequestId) {
            let localId = "local-\(record.clientRequestId)"
            pendingAttachmentSends[localId] = PendingAttachmentSend(
                data: nil, filename: record.filename, mimeType: record.mimeType, kind: record.kind,
                caption: record.caption, width: record.width, height: record.height,
                replyToId: record.replyToId, ttlSeconds: record.ttlSeconds ?? 0,
                clientRequestId: record.clientRequestId, failureReason: record.failureReason
            )
            sendStatus[localId] = .failed
            restored.append(makeOptimisticMessage(
                id: localId, text: record.caption, replyToId: record.replyToId, createdAt: record.createdAt
            ))
        }
        return restored
    }

    /// Retire les bulles restaurées dont la pièce jointe a quitté la file (envoyée ailleurs, par
    /// la reprise en arrière-plan de l'app) : elles resteraient « Non envoyé » à tort.
    private func pruneSettledRestoredAttachments() async {
        let restored = pendingAttachmentSends.filter { $0.value.clientRequestId != nil }
        guard !restored.isEmpty else { return }
        let live = Set(await service.pendingAttachments(conversationId: conversation.id).map(\.clientRequestId))
        for (localId, attachment) in restored {
            guard let requestId = attachment.clientRequestId, !live.contains(requestId) else { continue }
            pendingAttachmentSends[localId] = nil
            sendStatus[localId] = nil
            messages.removeAll { $0.id == localId }
        }
    }

    /// « Supprimer » : l'enregistrement quitte aussi la file durable, sinon la reprise de l'app
    /// enverrait plus tard une photo que l'utilisateur a abandonnée.
    private func discardOutboxRecords(for attachment: PendingAttachmentSend) async {
        if let requestId = attachment.clientRequestId {
            await service.discardPendingAttachment(clientRequestId: requestId)
            return
        }
        guard let data = attachment.data else { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        for record in await service.pendingAttachments(conversationId: conversation.id)
        where record.contentSha256 == digest {
            await service.discardPendingAttachment(clientRequestId: record.clientRequestId)
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
            let knownIds = Set(messages.map(\.id))
            // N'assigner que si quelque chose a changé : une liste identique redessinait tout le fil.
            let merged = Self.normalized(messages + fresh)
            if merged != messages { messages = merged }
            if !receiptsKnown, let receipts = page.readReceipts, receipts != readReceipts { readReceipts = receipts }
            advanceLastSync(with: fresh)
            await decryptLoadedMessages()
            let confirmed = localIdsConfirmed(by: fresh.filter { !knownIds.contains($0.id) })
            if !confirmed.isEmpty { messages.removeAll { confirmed.contains($0.id) } }
            await pruneSettledRestoredAttachments()
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
                E2EEV2HiddenMessagesStore.hide(messageRef: message.id, conversationId: conversation.id)
                messages.removeAll { $0.id == message.id }
            }
            return
        }
        do {
            try await service.deleteMessage(messageId: message.id, forEveryone: forEveryone)
            if forEveryone {
                // Même raison que pour l'édition : pas de rechargement complet de la liste.
                messages = messages.map { $0.id == message.id ? Self.copy(of: $0, deletedAt: Date()) : $0 }
                await refreshLatestPageState()
            } else {
                messages.removeAll { $0.id == message.id }
            }
        } catch {
            showActionError(error.userFacingMessage)
        }
    }

    private func markRead() async {
        // Tant que le fil est masqué, il n'est pas lu : l'autre personne ne verrait pas « Vu » à tort.
        guard !holdsProtection else { return }
        // Une bulle encore locale n'existe pas côté serveur : on lit jusqu'au dernier vrai message.
        let lastServerId = messages.last { !$0.id.hasPrefix("local-") }?.id
        readGate.lastMarkReadAt = Date()
        readGate.lastMarkedMessageId = lastServerId
        if usesV2 {
            // Lot serveur A7 : lecture jusqu'au dernier message, v1 et v2.
            try? await service.markReadToLatest(conversationId: conversation.id)
        } else {
            guard let lastServerId else { return }
            try? await service.markRead(conversationId: conversation.id, lastMessageId: lastServerId)
        }
        // Le badge restait allumé jusqu'au prochain rafraîchissement (SOC-23).
        await services.refreshInboxBadge(force: true)
    }

    /// Après un relevé (flux, relevé périodique, retour au premier plan) : un message reçu
    /// pendant que la conversation est à l'écran doit être marqué lu, une seule fois.
    private func markReadIfLastIncoming() async {
        guard isOnScreen, scenePhase == .active,
              let last = messages.last(where: { !$0.id.hasPrefix("local-") }),
              last.senderId != currentUserId,
              last.id != readGate.lastMarkedMessageId else { return }
        await markRead()
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
                ttlSeconds: ephemeralTTL,
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
    /// « Dans Équipe terrain » (groupe) ou « Avec Léa Martin » sous le titre des feuilles.
    private var sheetSubtitle: String {
        conversation.isGroup
            ? String(localized: "Dans \(conversationTitle)")
            : String(localized: "Avec \(conversationTitle)")
    }

    private var conversationTitle: String {
        if let renamedTitle, !renamedTitle.isEmpty { return renamedTitle }
        let title = conversation.displayTitle(excluding: currentUserId)
        return title.isEmpty ? String(localized: "Conversation") : title
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
            isEncryptedConversation: isE2EE,
            isGroup: conversation.isGroup
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
            // Le blocage se faisait sans aucun retour (AF-MSG-07) : on le dit,
            // on indique où l'annuler, et on quitte une conversation devenue muette.
            inAppNotifications.show(SQInAppNotificationItem(
                body: String(localized: "\(conversationTitle) est bloqué. Tu peux le débloquer depuis Amis."),
                variant: .success
            ))
            closeConversation()
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
            inAppNotifications.show(SQInAppNotificationItem(
                body: String(localized: "Expéditeur bloqué. Tu peux le débloquer depuis Amis."),
                variant: .success
            ))
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

    /// Copie d'un message avec le texte, l'édition ou la suppression mis à jour sur place.
    private static func copy(of item: MessageItem, content: String? = nil, editedAt: Date? = nil, deletedAt: Date? = nil) -> MessageItem {
        MessageItem(
            id: item.id,
            conversationId: item.conversationId,
            senderId: item.senderId,
            kind: item.kind,
            content: content ?? item.content,
            e2eeVersion: item.e2eeVersion,
            e2eeIvB64: item.e2eeIvB64,
            e2eeCiphertextB64: item.e2eeCiphertextB64,
            e2eeAadB64: item.e2eeAadB64,
            metadata: item.metadata,
            createdAt: item.createdAt,
            editedAt: editedAt ?? item.editedAt,
            deletedAt: deletedAt ?? item.deletedAt,
            expiresAt: item.expiresAt,
            replyToId: item.replyToId,
            threadReplyCount: item.threadReplyCount,
            sender: item.sender,
            attachments: item.attachments,
            reactions: item.reactions
        )
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
                    Text("+ \(sessions.count - 3) autre session")
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
            .padding(SQSpace.sm2)
            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
    }

    @ViewBuilder
    private func action(for session: LiveShareSession) -> some View {
        if session.status == "pending", session.sharerId == currentUserId {
            Button("Répondre", action: onManage)
                .font(SQType.micro.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(SQColor.brandRed)
                .foregroundStyle(SQColor.onAccent)
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
        return String(localized: "un participant")
    }
}

private struct LiveShareManagementSheet: View {
    @ObservedObject var coordinator: ConversationLiveShareCoordinator
    let conversation: MessageConversation
    let currentUserId: String
    let subtitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var mode: String
    @State private var selectedTargetId: String
    @State private var selectedBroadcastIds: Set<String>

    init(
        coordinator: ConversationLiveShareCoordinator,
        conversation: MessageConversation,
        currentUserId: String,
        subtitle: String
    ) {
        self.coordinator = coordinator
        self.conversation = conversation
        self.currentUserId = currentUserId
        self.subtitle = subtitle
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
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Partage en direct", subtitle: subtitle, closeIdentifier: "liveshare.close") { dismiss() }

                if !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Sessions en cours")
                            .sqKicker()
                            .padding(.leading, SQSpace.xs)
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

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Nouveau partage")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)

                    if conversation.isGroup {
                        SQSegmentedFilter(selection: $mode, options: [
                            (value: "targeted", label: "Une personne", icon: nil),
                            (value: "broadcast", label: "Plusieurs", icon: nil)
                        ])
                        .padding(.horizontal, -SQSpace.lg)
                        .accessibilityLabel("Destinataires")
                        targetsCard
                    }

                    TextField("Message facultatif", text: $message, axis: .vertical)
                        .lineLimit(1...3)
                        .sqHaloField()
                }

                if let error = coordinator.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }

                HStack(spacing: SQSpace.sm) {
                    GradientButton("Partager", systemImage: "dot.radiowaves.left.and.right") {
                        create(offerShare: true)
                    }
                    GradientButton("Demander", style: .secondary) {
                        create(offerShare: false)
                    }
                }
                .disabled(!canSubmit)

                disclosure
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
    }

    /// Une personne : un seul choix (radio) ; plusieurs : une coche par membre.
    private var targetsCard: some View {
        VStack(spacing: 0) {
            ForEach(targets) { participant in
                if participant.id != targets.first?.id { Divider().padding(.leading, 64) }
                let isSelected = mode == "targeted"
                    ? selectedTargetId == participant.userId
                    : selectedBroadcastIds.contains(participant.userId)
                Button {
                    Haptics.selection()
                    if mode == "targeted" {
                        selectedTargetId = participant.userId
                    } else {
                        binding(for: participant.userId).wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: SQSpace.md) {
                        SQAvatar(url: participant.user.avatarUrl, name: participant.user.displayName, size: 36)
                        Text(participant.user.displayName)
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: mode == "targeted"
                              ? (isSelected ? "largecircle.fill.circle" : "circle")
                              : (isSelected ? "checkmark.circle.fill" : "circle"))
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    /// Ce que le partage envoie et quand : en pied de feuille, sans encadré.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Label("Actif uniquement au premier plan", systemImage: "iphone.and.arrow.forward")
                .font(SQType.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
            Text("Sur iPhone, l’envoi se met en pause si tu verrouilles l’écran ou quittes SignalQuest. Il reprend au retour tant que la session n’a pas été arrêtée.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text("iOS partage la position, la technologie et l’opérateur disponibles. Apple n’expose pas les niveaux RSRP/RSRQ à l’app.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SQSpace.xs)
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
                if coordinator.isBusy { SQSpinner().controlSize(.small) }
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
                    .foregroundStyle(SQColor.onAccent)
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
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
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
            ?? String(localized: "un participant")
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
/// Action VoiceOver nommée de l'en-tête d'une conversation chiffrée : l'explication
/// du chiffrement, aussi disponible dans le menu ⋯.
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

/// Repères de lecture posés par cet appareil. Type référence rangé dans un `@State` :
/// les muter ne redessine pas la conversation.
private final class OwnReadGate {
    /// Dernier envoi de « lu » : l'événement `read_state` qu'il provoque revient dans la seconde.
    var lastMarkReadAt: Date = .distantPast
    /// Dernier message déjà marqué lu, pour ne pas le renvoyer à chaque relevé.
    var lastMarkedMessageId: String?
}

private struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

/// Le texte d'un message, sélectionnable à la main (copier un passage, chercher un mot).
private struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Sélectionner le texte", closeIdentifier: "message.select.close") { dismiss() }
                Text(verbatim: text)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
    }
}

/// Tout ce qu'il faut pour renvoyer une photo ou une note vocale sans doublon : les mêmes octets
/// repartent avec le même enregistrement de la file durable. `data` est nil pour une pièce jointe
/// restaurée de cette file (`clientRequestId` renseigné) : le service sait alors la rejouer seul.
private struct PendingAttachmentSend {
    let data: Data?
    let filename: String
    let mimeType: String
    let kind: String
    let caption: String
    let width: Int?
    let height: Int?
    let replyToId: String?
    let ttlSeconds: Int
    var clientRequestId: String?
    /// Cause du dernier refus, montrée sous la bulle « Non envoyé » (U06).
    var failureReason: String? = nil
}

/// Pièce jointe en attente dans le compositeur : prête à partir telle quelle
/// (photo déjà ré-encodée, vidéo ou fichier dans la limite de 10 Mo).
private struct StagedAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let filename: String
    let mimeType: String
    /// « IMAGE » ou « FILE », comme `PendingAttachmentSend.kind`.
    let kind: String
    let width: Int?
    let height: Int?

    static func == (lhs: StagedAttachment, rhs: StagedAttachment) -> Bool { lhs.id == rhs.id }
}

/// Plateau des pièces en attente, au-dessus du champ : une tuile par pièce, avec
/// de quoi la retirer avant l'envoi.
private struct StagedAttachmentsTray: View {
    let items: [StagedAttachment]
    let onRemove: (UUID) -> Void

    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(items) { item in
                    ZStack(alignment: .topTrailing) {
                        content(of: item)
                            .frame(width: tile, height: tile)
                            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SQColor.onInk)
                                .frame(width: 22, height: 22)
                                .background(SQColor.label, in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 14, y: -14)
                        .accessibilityLabel(Text("Retirer la pièce jointe"))
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
        }
        .accessibilityIdentifier("composer.staged")
    }

    @ViewBuilder
    private func content(of item: StagedAttachment) -> some View {
        if item.kind == "IMAGE", let image = PendingThumbnailCache.image(for: item.id.uuidString, data: item.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(Text("Photo jointe"))
        } else {
            VStack(spacing: 2) {
                Image(systemName: item.mimeType.hasPrefix("video/") ? "film" : "doc")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SQColor.accentInk)
                Text(verbatim: item.filename)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(SQSpace.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SQColor.chip)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Glisser-déposer sur la conversation, et réception d'un partage : regroupés
/// dans un modificateur pour ne pas allonger la chaîne du corps de la vue.
private struct ConversationInputModifier: ViewModifier {
    let acceptsDrops: Bool
    let pendingShareId: UUID?
    let onProviders: ([NSItemProvider]) -> Void
    let onPendingShare: () async -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: ConversationInputImport.dropTypes, isTargeted: $isTargeted) { providers in
                guard acceptsDrops else { return false }
                onProviders(providers)
                return true
            }
            .overlay {
                if isTargeted && acceptsDrops {
                    RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                        .strokeBorder(SQColor.brandRed, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .overlay {
                            Text("Dépose ici pour joindre à la conversation")
                                .font(SQType.body.weight(.semibold))
                                .foregroundStyle(SQColor.accentInk)
                                .multilineTextAlignment(.center)
                                .padding(SQSpace.lg)
                        }
                        .padding(SQSpace.sm)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: pendingShareId) { await onPendingShare() }
    }
}

/// Lecture de ce qui est glissé ou collé : texte, lien, image, vidéo, fichier.
/// Les fichiers sont lus en mémoire dans le rappel du système, qui seul les
/// garde le temps de la lecture ; leur taille est vérifiée avant.
enum ConversationInputImport {
    static let dropTypes: [UTType] = [.image, .movie, .fileURL, .url, .text, .data]

    struct File: Sendable {
        let data: Data
        let fileName: String
        let uti: String
    }

    struct Failure: Sendable {
        enum Reason: Sendable { case tooLarge, unreadable }
        let kind: ShareInbox.Kind
        let reason: Reason

        var message: String {
            switch (kind, reason) {
            case (.image, .tooLarge): return String(localized: "Cette image dépasse 20 Mo.")
            case (.image, .unreadable): return String(localized: "Image illisible.")
            case (.video, .tooLarge): return String(localized: "Cette vidéo dépasse 10 Mo. Choisis-en une plus courte.")
            case (.file, .tooLarge): return String(localized: "Ce fichier dépasse 10 Mo.")
            default: return String(localized: "Ce fichier est illisible.")
            }
        }
    }

    enum Item: Sendable {
        case text(String)
        case file(File)
        case failure(Failure)
    }

    @MainActor
    static func items(from providers: [NSItemProvider]) async -> [Item] {
        var result: [Item] = []
        for provider in providers {
            let identifiers = provider.registeredTypeIdentifiers
            func first(conformingTo type: UTType) -> String? {
                identifiers.first { UTType($0)?.conforms(to: type) == true }
            }
            if let id = first(conformingTo: .image) {
                result.append(await loadFile(provider, identifier: id, kind: .image))
            } else if let id = first(conformingTo: .movie) {
                result.append(await loadFile(provider, identifier: id, kind: .video))
            } else if let id = identifiers.first(where: { id in
                guard let type = UTType(id) else { return false }
                return type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text)
                    && !type.conforms(to: .propertyList)
            }) {
                result.append(await loadFile(provider, identifier: id, kind: .file))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let value = await loadString(provider, identifier: UTType.url.identifier) { result.append(.text(value)) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                if let value = await loadString(provider, identifier: UTType.text.identifier) { result.append(.text(value)) }
            }
        }
        return result
    }

    private struct Loaded: @unchecked Sendable {
        let value: NSSecureCoding?
    }

    @MainActor
    private static func loadString(_ provider: NSItemProvider, identifier: String) async -> String? {
        let loaded: Loaded = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                continuation.resume(returning: Loaded(value: item))
            }
        }
        switch loaded.value {
        case let url as URL: return url.absoluteString
        case let string as String: return string
        case let attributed as NSAttributedString: return attributed.string
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    @MainActor
    private static func loadFile(_ provider: NSItemProvider, identifier: String, kind: ShareInbox.Kind) async -> Item {
        let limit = kind == .image ? ShareInbox.maxImageBytes : MessageAttachmentOutboxStore.maximumSourceBytes
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url, let size = try? ShareInbox.byteCount(of: url), size > 0 else {
                    continuation.resume(returning: .failure(Failure(kind: kind, reason: .unreadable)))
                    return
                }
                guard size <= limit else {
                    continuation.resume(returning: .failure(Failure(kind: kind, reason: .tooLarge)))
                    return
                }
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: .failure(Failure(kind: kind, reason: .unreadable)))
                    return
                }
                continuation.resume(returning: .file(File(data: data, fileName: url.lastPathComponent, uti: identifier)))
            }
        }
    }
}

/// Miniature d'une photo en attente d'envoi, calculée une fois par bulle.
private enum PendingThumbnailCache {
    @MainActor private static let cache = NSCache<NSString, UIImage>()

    @MainActor static func image(for id: String, data: Data) -> UIImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        guard let image = ImagePipeline.downsample(data: data, maxPixel: 280) else { return nil }
        cache.setObject(image, forKey: id as NSString)
        return image
    }
}

/// Vidéo choisie dans la photothèque : copiée en fichier temporaire à l'import.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Glisser une rangée de message vers la droite pour y répondre. L'état du glissement vit dans ce
/// modificateur : seule la rangée touchée se redessine, pas toute la conversation. Le geste est
/// simultané avec le défilement et ne démarre que sur un mouvement nettement horizontal, donc le
/// défilement vertical et l'appui long (menu contextuel) restent intacts.
private struct SwipeToReply: ViewModifier {
    let isEnabled: Bool
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distance à partir de laquelle le relâchement déclenche la réponse.
    private let threshold: CGFloat = 56

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(armed ? SQColor.onAccent : SQColor.labelSecondary)
                    .frame(width: 30, height: 30)
                    .background(armed ? SQColor.brandRed : SQColor.chip, in: Circle())
                    .opacity(Double(min(offset / threshold, 1)))
                    .accessibilityHidden(true)
            }
            .simultaneousGesture(drag, including: isEnabled ? .all : .subviews)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let t = value.translation
                // Départ : vers la droite et nettement plus horizontal que vertical.
                guard offset > 0 || (t.width > 0 && t.width > abs(t.height) * 1.5) else { return }
                let raw = max(t.width, 0)
                // Résistance au-delà du seuil.
                offset = raw <= threshold ? raw : threshold + (raw - threshold) * 0.3
                let nowArmed = offset >= threshold
                if nowArmed != armed {
                    armed = nowArmed
                    if nowArmed { Haptics.light() }
                }
            }
            .onEnded { _ in
                let shouldReply = armed
                armed = false
                if offset != 0 {
                    withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { offset = 0 }
                }
                if shouldReply { onReply() }
            }
    }
}

/// Photos de la conversation ouvertes dans la visionneuse, avec celle qu'on a touchée.
private struct ImageViewerSession: Identifiable {
    let id = UUID()
    let targets: [MessageImageTarget]
    let initialIndex: Int
}

private struct ForwardPayload: Identifiable {
    let id = UUID()
    let text: String
    /// Le message vient d'une conversation chiffrée : il ne peut aller que vers une autre conversation chiffrée.
    let sourceIsEncrypted: Bool
}

/// Emojis courants pour réagir à un message au-delà des six de la palette rapide. Pas de
/// sélecteur système : il n'existe pas en SwiftUI, et une grille fixe évite toute dépendance.
private struct EmojiReactionSheet: View {
    let chosen: Set<String>
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private static let emojis = [
        "👍", "👎", "❤️", "😂", "😮", "😢", "🙏", "👏", "🔥", "🎉", "😍", "🥰",
        "😘", "😎", "🤩", "🤔", "😅", "😭", "😡", "🥳", "😴", "🙄", "🤯", "😱",
        "🙌", "👌", "✌️", "🤝", "💪", "👀", "🤞", "🫡", "😬", "🤗", "🥹", "😇",
        "🧡", "💛", "💚", "💙", "💜", "🖤", "💔", "💯", "✅", "❌", "⚡", "🚀",
        "📡", "📶", "📍", "🗼", "🛰️", "📱", "🔋", "💡", "⭐", "🏆", "🎯", "☕",
        "🍕", "🍻", "🌞", "🌧️"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Choisir un emoji", closeIdentifier: "emoji.close") { dismiss() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: SQSpace.xs)], spacing: SQSpace.xs) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button {
                            Haptics.light()
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.title2)
                                .frame(width: 48, height: 48)
                                .background(chosen.contains(emoji) ? SQColor.accentSoft : Color.clear, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Réagir avec \(emoji)")
                    }
                }
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
    }
}

/// Transfert d'un texte vers une autre conversation. Une cible chiffrée est toujours permise (l'envoi
/// y chiffre) ; depuis une conversation chiffrée, seules les cibles chiffrées sont proposées, car un
/// texte déchiffré ne part jamais en clair. Chaque cible reçoit le texte par son propre chemin d'envoi :
/// ordinaire, chiffré v1 ou messagerie v2. Rien ne passe par le presse-papiers.
private struct ForwardMessageSheet: View {
    let text: String
    let sourceIsEncrypted: Bool
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    let currentUserId: String?
    let excludedConversationId: String
    let onSent: () -> Void

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [MessageConversation] = []
    /// Chemin d'envoi de chaque cible, établi une fois au chargement (l'état v2 se lit sur disque).
    @State private var routes: [String: EncryptedConversationSurfaces.ForwardRoute] = [:]
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var sendingId: String?
    @State private var sendError: String?

    private var targets: [MessageConversation] {
        conversations.filter {
            $0.id != excludedConversationId
                && EncryptedConversationSurfaces.allowsForward(fromEncrypted: sourceIsEncrypted, toEncrypted: $0.e2eeEnabled == true)
                && routes[$0.id] != .unavailable
        }
    }

    private func route(for target: MessageConversation) -> EncryptedConversationSurfaces.ForwardRoute {
        let encrypted = target.e2eeEnabled == true
        return EncryptedConversationSurfaces.forwardRoute(
            toEncrypted: encrypted,
            targetIsV2: encrypted && EncryptedConversationSurfaces.isV2(target),
            v2Enabled: services.e2eeV2Messaging.readsEnabled && services.e2eeV2Messaging.writesEnabled
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(
                    title: "Transférer",
                    subtitle: String(text.prefix(80)),
                    closeIdentifier: "forward.close"
                ) { dismiss() }
                content
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ErrorStateView(title: "Conversations indisponibles", message: loadError) {
                Task { await load() }
            }
        } else if !hasLoaded {
            SQSpinner()
                .tint(SQColor.brandRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.xl)
        } else if targets.isEmpty {
            EmptyStateView(
                title: "Aucune conversation",
                message: sourceIsEncrypted
                    ? "Un message chiffré ne se transfère que vers une autre conversation chiffrée."
                    : "Tu n’as pas d’autre conversation où transférer ce message.",
                systemImage: "bubble.left.and.bubble.right"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(targets) { target in
                    if target.id != targets.first?.id { Divider().padding(.leading, 64) }
                    Button {
                        Task { await send(to: target) }
                    } label: {
                        HStack(spacing: SQSpace.md) {
                            ConversationAvatar(conversation: target, currentUserId: currentUserId, size: 40)
                                .accessibilityHidden(true)
                            Text(verbatim: target.displayTitle(excluding: currentUserId))
                                .font(SQType.rowTitle)
                                .foregroundStyle(SQColor.label)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if sendingId == target.id {
                                SQSpinner().tint(SQColor.brandRed)
                            }
                        }
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(sendingId != nil)
                }
            }
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            if let sendError {
                Text(verbatim: sendError)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .accessibilityIdentifier("forward.error")
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let loaded = try await service.conversations()
            conversations = loaded
            routes = Dictionary(loaded.map { ($0.id, route(for: $0)) }, uniquingKeysWith: { first, _ in first })
            hasLoaded = true
        } catch {
            loadError = error.userFacingMessage
        }
    }

    private func send(to target: MessageConversation) async {
        guard sendingId == nil else { return }
        sendingId = target.id
        sendError = nil
        do {
            switch routes[target.id] ?? .plain {
            case .plain:
                _ = try await service.sendText(
                    text, in: target, replyToId: nil, e2ee: nil, idempotencyKey: UUID().uuidString, ttlSeconds: 0
                )
            case .legacyEncrypted:
                // Le service chiffre avec la clé v1 ; verrouillée, il refuse et rien ne part en clair.
                _ = try await service.sendText(
                    text, in: target, replyToId: nil, e2ee: e2ee ?? services.e2ee,
                    idempotencyKey: UUID().uuidString, ttlSeconds: 0
                )
            case .v2:
                let result = await services.e2eeV2Messaging.send(
                    .init(body: .text(text), replyToRef: nil, mentions: [], ttlSeconds: 0),
                    clientRequestId: UUID().uuidString, conversationId: target.id, isGroup: target.isGroup,
                    participantIds: target.participants.map(\.userId)
                )
                if let failure = EncryptedConversationSurfaces.v2SendFailureMessage(result, keptForRetry: false) {
                    throw ForwardFailure(message: failure)
                }
            case .unavailable:
                throw ForwardFailure(message: String(localized: "Cette conversation chiffrée n’est pas disponible dans cette version de SignalQuest."))
            }
            onSent()
            dismiss()
        } catch {
            sendError = (error as? ForwardFailure)?.message ?? error.userFacingMessage
            sendingId = nil
            Haptics.error()
        }
    }

    private struct ForwardFailure: Error {
        let message: String
    }
}


/// Écran enregistré ou diffusé (AirPlay compris), lu sur les scènes de l'app.
enum ScreenCaptureState {
    @MainActor static var isCaptured: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}

private struct SQMessagesCloseDetailKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}

extension EnvironmentValues {
    /// Posé quand la conversation s'affiche à droite de la liste (iPad) : il lève la
    /// sélection, et la conversation n'a plus de bouton retour. `nil` sur iPhone.
    var sqMessagesCloseDetail: (() -> Void)? {
        get { self[SQMessagesCloseDetailKey.self] }
        set { self[SQMessagesCloseDetailKey.self] = newValue }
    }
}
